local M = {}
local ai_prompt = require("codereview.ai.prompt")

function M.build_file_plan_prompt(file, opts)
  local path = file.new_path or file.old_path
  local parts = {
    "You are creating an implementation plan for changes in a file.",
    "",
    "## Instructions",
    "",
    "Analyze the diff below and create tasks to complete or improve this implementation.",
    "Output a JSON array in a ```json code block:",
    '[{"file": "<path>", "line": <number>, "task": "<what to do>", "reason": "<why>"}]',
    "",
    "Focus on: incomplete implementations, missing error handling, TODOs, edge cases, missing tests.",
    "If the code looks complete, output `[]`.",
    "",
    "## File: " .. path,
    "```diff",
    ai_prompt.annotate_diff_with_lines(file.diff or ""),
    "```",
  }

  return table.concat(parts, "\n") .. ai_prompt.progress_suffix(opts and opts.progress_path)
end

--- Build a prompt for a batch of files (multiple diffs in one AI call).
--- Stable instructions first (cache-friendly); per-file diffs after "## Files".
---
--- @param files table[]  List of {new_path, old_path, diff}
--- @param opts  table?   {progress_path?: string}
--- @return string
function M.build_batch_plan_prompt(files, opts)
  local parts = {
    "You are creating an implementation plan for changes in files.",
    "",
    "## Instructions",
    "",
    "Analyze the diffs below and create tasks to complete or improve these implementations.",
    "Output a JSON array in a ```json code block:",
    '[{"file": "<path>", "line": <number>, "task": "<what to do>", "reason": "<why>"}]',
    "",
    "Focus on: incomplete implementations, missing error handling, TODOs, edge cases, missing tests.",
    "If the code looks complete, output `[]`.",
  }

  table.insert(parts, "")
  table.insert(parts, "## Files")

  for _, file in ipairs(files) do
    local path = file.new_path or file.old_path
    table.insert(parts, "")
    table.insert(parts, "### " .. path)
    table.insert(parts, "```diff")
    table.insert(parts, ai_prompt.annotate_diff_with_lines(file.diff or ""))
    table.insert(parts, "```")
  end

  return table.concat(parts, "\n") .. ai_prompt.progress_suffix(opts and opts.progress_path)
end

function M.parse_file_plan_output(output)
  if not output or output == "" then
    return {}
  end

  local json_str = output:match("```json%s*\n(.+)\n```")
  if not json_str then
    json_str = output:match("%[.+%]")
  end
  if not json_str then
    return {}
  end

  local ok, data = pcall(vim.json.decode, json_str)
  if not ok or type(data) ~= "table" then
    return {}
  end

  local tasks = {}
  for _, item in ipairs(data) do
    if type(item) == "table" and item.file and item.task then
      table.insert(tasks, {
        file = item.file,
        line = tonumber(item.line),
        task = item.task,
        reason = item.reason or "",
      })
    end
  end
  return tasks
end

function M.build_combine_prompt(branch, base, tasks)
  local parts = {
    "You are writing a one-paragraph summary of an implementation plan.",
    "",
    "## Branch",
    branch,
    "",
    "## Base",
    base,
    "",
    "## Tasks",
  }

  for i, t in ipairs(tasks) do
    table.insert(parts, string.format("%d. `%s:%s` — %s", i, t.file, t.line or "?", t.task))
  end

  table.insert(parts, "")
  table.insert(parts, "## Instructions")
  table.insert(parts, "Write a brief (2-4 sentence) summary of what this implementation plan covers.")
  table.insert(parts, "Output the summary in a ```markdown code block.")

  return table.concat(parts, "\n")
end

function M.parse_summary(output)
  if not output or output == "" then
    return ""
  end
  local content = output:match("```markdown%s*\n(.-)\n```")
  if content then
    return vim.trim(content)
  end
  content = output:match("```[%w]*%s*\n(.-)\n```")
  if content then
    return vim.trim(content)
  end
  return vim.trim(output)
end

function M.format_plan_markdown(branch, base, summary, tasks)
  local date = os.date("%Y-%m-%d")
  local parts = {
    "# Implementation Plan: " .. branch,
    "",
    "Generated: " .. date,
    "Branch: " .. branch,
    "Base: " .. base,
    "",
    "## Summary",
    "",
    summary or "(No summary generated)",
    "",
    "## Tasks",
    "",
  }

  for i, t in ipairs(tasks) do
    local line_str = t.line and tostring(t.line) or "?"
    table.insert(parts, string.format("### %d. %s:%s", i, t.file, line_str))
    table.insert(parts, t.task)
    table.insert(parts, "")
    if t.reason and t.reason ~= "" then
      table.insert(parts, "**Why:** " .. t.reason)
      table.insert(parts, "")
    end
  end

  return table.concat(parts, "\n")
end

return M
