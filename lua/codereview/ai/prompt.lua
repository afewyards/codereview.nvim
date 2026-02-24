local M = {}

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
    table.insert(parts, file.diff or "")
    table.insert(parts, "```")
    table.insert(parts, "")
  end

  table.insert(parts, "## Instructions")
  table.insert(parts, "")
  table.insert(parts, "Review this MR. Output a JSON array in a ```json code block.")
  table.insert(parts, 'Each item: {"file": "path", "line": <new_line_number>, "severity": "error"|"warning"|"info"|"suggestion", "comment": "text"}')
  table.insert(parts, 'Use \\n inside "comment" strings for line breaks (e.g. "Problem.\\n\\nSuggested fix:").')
  table.insert(parts, "If no issues, output `[]`.")
  table.insert(parts, "Focus on: bugs, security, error handling, edge cases, naming, clarity.")
  table.insert(parts, "Do NOT comment on style or formatting.")

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
        severity = item.severity or "info",
        comment = item.comment,
        status = "pending",
      })
    end
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

function M.build_orchestrator_prompt(review, diffs)
  local file_list = {}
  for i, file in ipairs(diffs) do
    local path = file.new_path or file.old_path
    local line_count = select(2, (file.diff or ""):gsub("\n", "")) + 1
    table.insert(file_list, string.format("%d. `%s` (%d diff lines)", i, path, line_count))
  end

  local per_file_sections = {}
  for _, file in ipairs(diffs) do
    local path = file.new_path or file.old_path
    local others = {}
    for _, f in ipairs(diffs) do
      local p = f.new_path or f.old_path
      if p ~= path then table.insert(others, p) end
    end
    table.insert(per_file_sections, table.concat({
      "### File: `" .. path .. "`",
      "",
      "Other changed files: " .. (next(others) and table.concat(others, ", ") or "none"),
      "",
      "```diff",
      file.diff or "",
      "```",
    }, "\n"))
  end

  return table.concat({
    "You are orchestrating a parallel code review of a merge request.",
    "",
    "## MR Title",
    review.title or "",
    "",
    "## MR Description",
    review.description or "(no description)",
    "",
    "## Changed Files",
    "",
    table.concat(file_list, "\n"),
    "",
    "## Per-File Diffs",
    "",
    table.concat(per_file_sections, "\n\n"),
    "",
    "## Instructions",
    "",
    "For EACH file above, use the Task tool to spawn a subagent that reviews that file.",
    "Launch ALL subagents in a SINGLE message (parallel Task calls).",
    "",
    "Each Task call must use:",
    '- `subagent_type`: `"code-review"`',
    "- `prompt`: Include the MR title, description, list of other changed files, and ONLY that file's diff.",
    "  End the prompt with these review instructions:",
    '  "Review this file. Output a JSON array in a ```json block.',
    '  Each item: {\\"file\\": \\"path\\", \\"line\\": <new_line_number>, \\"severity\\": \\"error\\"|\\"warning\\"|\\"info\\"|\\"suggestion\\", \\"comment\\": \\"text\\"}.',
    '  Use \\\\n for line breaks in comments. Focus on: bugs, security, error handling, edge cases, naming, clarity.',
    '  Do NOT comment on style or formatting. If no issues, output `[]`."',
    "",
    "After ALL subagents complete, synthesize the results:",
    "1. Merge all JSON arrays into one.",
    "2. Remove duplicate findings.",
    "3. Add any cross-file insights (e.g. API contract mismatches between files).",
    "4. Output the final combined JSON array in a ```json code block.",
    "",
    "If a subagent fails, include a comment noting the error for that file and continue with other results.",
  }, "\n")
end

return M
