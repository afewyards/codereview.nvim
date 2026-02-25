local M = {}

--- Annotate diff text with explicit line numbers so an LLM can reference exact lines.
---
--- For each line inside a hunk:
---   - context/added lines get a prefix like `L 38: ` (new file line number)
---   - deleted lines get a prefix like `   : ` (no new line number)
--- Lines outside hunks (diff headers) are kept as-is.
---
--- @param diff_text string  Raw unified diff text
--- @return string           Annotated diff text
function M.annotate_diff_with_lines(diff_text)
  if not diff_text or diff_text == "" then return diff_text or "" end

  -- Split into lines, preserving trailing newline by tracking it separately
  local trailing_newline = diff_text:sub(-1) == "\n"
  local text = trailing_newline and diff_text:sub(1, -2) or diff_text
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end

  -- First pass: find the maximum new_line number to compute padding width
  local max_new_line = 0
  local in_hunk = false
  local tmp_new_line = 0

  for _, line in ipairs(lines) do
    local ns = line:match("^@@ %-[%d,]+ %+(%d+)[,%d]* @@")
    if ns then
      in_hunk = true
      tmp_new_line = tonumber(ns)
    elseif in_hunk then
      local prefix = line:sub(1, 1)
      if prefix == "+" then
        if tmp_new_line > max_new_line then max_new_line = tmp_new_line end
        tmp_new_line = tmp_new_line + 1
      elseif prefix == " " or line == "" then
        if tmp_new_line > max_new_line then max_new_line = tmp_new_line end
        tmp_new_line = tmp_new_line + 1
      end
      -- "-" and "\" lines don't increment new_line
    end
  end

  -- Build format strings with consistent padding width
  local num_width = math.max(1, #tostring(max_new_line))
  -- e.g. for width 3: "L%3d: " produces "L 38: " / "L138: "
  local fmt_num = string.format("L%%%dd: ", num_width)
  -- Deleted-line padding: "L" replaced by spaces, same total prefix width
  -- "L" (1) + num_width + ": " (2) = num_width + 3 chars
  local fmt_pad = string.rep(" ", num_width + 3)

  -- Second pass: annotate lines
  local result = {}
  in_hunk = false
  local old_line = 0
  local new_line = 0

  for _, line in ipairs(lines) do
    local os, ns = line:match("^@@ %-(%d+)[,%d]* %+(%d+)[,%d]* @@")
    if os then
      in_hunk = true
      old_line = tonumber(os)
      new_line = tonumber(ns)
      table.insert(result, line)
    elseif in_hunk then
      local prefix = line:sub(1, 1)
      if prefix == "-" then
        table.insert(result, fmt_pad .. line)
        old_line = old_line + 1
      elseif prefix == "+" then
        table.insert(result, string.format(fmt_num, new_line) .. line)
        new_line = new_line + 1
      elseif prefix == " " then
        table.insert(result, string.format(fmt_num, new_line) .. line)
        old_line = old_line + 1
        new_line = new_line + 1
      elseif line == "" then
        -- Empty context line (diff may omit the space prefix for blank lines)
        table.insert(result, string.format(fmt_num, new_line) .. line)
        old_line = old_line + 1
        new_line = new_line + 1
      else
        -- "\ No newline at end of file" and similar markers — keep as-is
        table.insert(result, line)
      end
    else
      table.insert(result, line)
    end
  end

  local out = table.concat(result, "\n")
  if trailing_newline then out = out .. "\n" end
  return out
end

function M.build_review_prompt(review, diffs)
  local parts = {
    "You are reviewing a merge request.",
    "",
    "## MR Title",
    review.title or "",
    "",
    "## MR Description",
    review.description or "(no description)",
    "",
    "## Changed Files",
    "",
  }

  for _, file in ipairs(diffs) do
    table.insert(parts, "### " .. (file.new_path or file.old_path))
    table.insert(parts, "```diff")
    table.insert(parts, M.annotate_diff_with_lines(file.diff or ""))
    table.insert(parts, "```")
    table.insert(parts, "")
  end

  table.insert(parts, "## Instructions")
  table.insert(parts, "")
  table.insert(parts, "Each diff line is prefixed with its line number (e.g., L38:). Use the EXACT number from the L-prefix for the line field.")
  table.insert(parts, "Review this MR. Output a JSON array in a ```json code block.")
  table.insert(parts, 'Each item: {"file": "path", "line": <number from L-prefix>, "code": "<exact content of that line>", "severity": "error"|"warning"|"info"|"suggestion", "comment": "text"}')
  table.insert(parts, 'The "code" field must contain the trimmed source code from the line you are commenting on (without the diff +/- prefix).')
  table.insert(parts, 'Use \\n inside "comment" strings for line breaks (e.g. "Problem.\\n\\nSuggested fix:").')
  table.insert(parts, "If no issues, output `[]`.")
  table.insert(parts, "Focus on: bugs, security, error handling, edge cases, naming, clarity.")
  table.insert(parts, "Do NOT comment on style or formatting.")
  table.insert(parts, "IMPORTANT: Find the L-prefix on the exact code line your comment applies to and use that number. Do NOT guess or count lines yourself.")

  return table.concat(parts, "\n")
end

function M.parse_review_output(output)
  if not output or output == "" then return {} end

  local log = require("codereview.log")

  -- Use greedy match (.+) to capture the full JSON block (handles nested fences/brackets)
  local json_str = output:match("```json%s*\n(.+)\n```")
  if not json_str then
    -- Fallback: greedy match for a JSON array (handles ] inside strings)
    json_str = output:match("%[.+%]")
  end
  if not json_str then
    log.debug("AI parse: no JSON block found in output (length=" .. #output .. ")")
    return {}
  end

  log.debug("AI parse: extracted JSON length=" .. #json_str)

  local ok, data = pcall(vim.json.decode, json_str)
  if not ok or type(data) ~= "table" then
    log.warn("AI parse: JSON decode failed: " .. tostring(data))
    return {}
  end

  local suggestions = {}
  for _, item in ipairs(data) do
    if type(item) == "table" and item.file and item.line and item.comment then
      local has_newlines = item.comment:find("\n") ~= nil
      log.debug(string.format("AI parse: %s:%s comment=%d chars, newlines=%s",
        item.file, tostring(item.line), #item.comment, tostring(has_newlines)))
      table.insert(suggestions, {
        file = item.file,
        line = tonumber(item.line),
        code = type(item.code) == "string" and vim.trim(item.code) or nil,
        severity = item.severity or "info",
        comment = item.comment,
        status = "pending",
      })
    end
  end

  -- Filter by review_level
  local cfg = require("codereview.config").get()
  local level = cfg.ai.review_level or "info"
  if level ~= "info" then
    local rank = { info = 1, suggestion = 2, warning = 3, error = 4 }
    local threshold = rank[level] or 1
    local filtered = {}
    for _, s in ipairs(suggestions) do
      if (rank[s.severity] or 1) >= threshold then
        table.insert(filtered, s)
      end
    end
    suggestions = filtered
  end

  return suggestions
end

function M.build_mr_prompt(branch, diff)
  return table.concat({
    "I'm creating a merge request for branch: " .. branch,
    "",
    "Here's the diff:",
    "```diff",
    diff,
    "```",
    "",
    "Write a concise MR title (one line, no prefix) and a clear description.",
    "Format:",
    "## Title",
    "<title>",
    "",
    "## Description",
    "<description with bullet points>",
  }, "\n")
end

function M.parse_mr_draft(output)
  local title = output:match("## Title%s*\n([^\n]+)")
  local description = output:match("## Description%s*\n(.*)")

  if title and description then
    return vim.trim(title), vim.trim(description)
  end

  local lines = vim.split(output, "\n")
  title = lines[1] or ""
  local desc_start = 2
  while desc_start <= #lines and vim.trim(lines[desc_start]) == "" do
    desc_start = desc_start + 1
  end
  description = table.concat(lines, "\n", desc_start)
  return vim.trim(title), vim.trim(description)
end

function M.build_file_review_prompt(review, file, summaries)
  local path = file.new_path or file.old_path
  local parts = {
    "You are reviewing a single file in a merge request.",
    "",
    "## MR Title",
    review.title or "",
    "",
    "## MR Description",
    review.description or "(no description)",
    "",
  }

  -- Other changed files with summaries
  local others = {}
  for fpath, summary in pairs(summaries or {}) do
    if fpath ~= path then
      table.insert(others, string.format("- `%s`: %s", fpath, summary))
    end
  end
  if #others > 0 then
    table.insert(parts, "## Other Changed Files in This MR")
    for _, line in ipairs(others) do
      table.insert(parts, line)
    end
    table.insert(parts, "")
  end

  table.insert(parts, "## File Under Review: " .. path)
  table.insert(parts, "```diff")
  table.insert(parts, M.annotate_diff_with_lines(file.diff or ""))
  table.insert(parts, "```")
  table.insert(parts, "")
  table.insert(parts, "## Instructions")
  table.insert(parts, "")
  table.insert(parts, "Each diff line is prefixed with its line number (e.g., L38:). Use the EXACT number from the L-prefix for the line field.")
  table.insert(parts, "Review this file. Output a JSON array in a ```json code block.")
  table.insert(parts, 'Each item: {"file": "' .. path .. '", "line": <number from L-prefix>, "code": "<exact content of that line>", "severity": "error"|"warning"|"info"|"suggestion", "comment": "text"}')
  table.insert(parts, 'The "code" field must contain the trimmed source code from the line you are commenting on (without the diff +/- prefix).')
  table.insert(parts, 'Use \\n inside "comment" strings for line breaks.')
  table.insert(parts, "If no issues, output `[]`.")
  table.insert(parts, "Focus on: bugs, security, error handling, edge cases, naming, clarity.")
  table.insert(parts, "Do NOT comment on style or formatting.")
  table.insert(parts, "IMPORTANT: Find the L-prefix on the exact code line your comment applies to and use that number. Do NOT guess or count lines yourself.")

  return table.concat(parts, "\n")
end

function M.build_summary_prompt(review, diffs)
  local parts = {
    "You are summarizing changes in a merge request for context.",
    "",
    "## MR Title",
    review.title or "",
    "",
    "## MR Description",
    review.description or "(no description)",
    "",
    "## Changed Files",
    "",
  }

  for _, file in ipairs(diffs) do
    table.insert(parts, "### " .. (file.new_path or file.old_path))
    table.insert(parts, "```diff")
    table.insert(parts, file.diff or "")
    table.insert(parts, "```")
    table.insert(parts, "")
  end

  table.insert(parts, "## Instructions")
  table.insert(parts, "")
  table.insert(parts, "For each file, write a one-sentence summary of what changed.")
  table.insert(parts, "Output a JSON object in a ```json code block:")
  table.insert(parts, '{"path/to/file.lua": "Summary of changes", ...}')

  return table.concat(parts, "\n")
end

function M.parse_summary_output(output)
  if not output or output == "" then return {} end

  local json_str = output:match("```json%s*\n(.+)\n```")
  if not json_str then
    json_str = output:match("%{.+%}")
  end
  if not json_str then return {} end

  local ok, data = pcall(vim.json.decode, json_str)
  if not ok or type(data) ~= "table" then return {} end

  return data
end

return M
