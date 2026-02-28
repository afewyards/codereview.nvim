-- lua/codereview/ai/summary.lua
local M = {}

--- Build a prompt asking for a brief, constructive, positive review summary.
--- @param review { title: string, description: string }
--- @param diffs { new_path?: string, old_path?: string, diff?: string }[]
--- @param suggestions { status: string, comment: string, severity: string }[]
--- @return string
function M.build_review_summary_prompt(review, diffs, suggestions)
  -- Count suggestion stats
  local accepted, dismissed, pending = 0, 0, 0
  for _, s in ipairs(suggestions or {}) do
    if s.status == "accepted" then
      accepted = accepted + 1
    elseif s.status == "dismissed" then
      dismissed = dismissed + 1
    else
      pending = pending + 1
    end
  end

  local parts = {
    "You are writing a brief review summary for a merge request.",
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

  for _, file in ipairs(diffs or {}) do
    local path = file.new_path or file.old_path or "unknown"
    local diff_text = file.diff or ""
    -- Count lines added/removed
    local added, removed = 0, 0
    for line in (diff_text .. "\n"):gmatch("(.-)\n") do
      if line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
        added = added + 1
      elseif line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
        removed = removed + 1
      end
    end
    table.insert(parts, string.format("- `%s` (+%d/-%d lines)", path, added, removed))
  end

  table.insert(parts, "")
  table.insert(parts, "## AI Review Stats")
  table.insert(parts, string.format("- Accepted suggestions: %d", accepted))
  table.insert(parts, string.format("- Dismissed suggestions: %d", dismissed))
  table.insert(parts, string.format("- Pending suggestions: %d", pending))
  table.insert(parts, "")
  table.insert(parts, "## Instructions")
  table.insert(parts, "")
  table.insert(parts, "Write a brief (2-4 sentence), constructive, and positive review summary.")
  table.insert(parts, "Highlight what the PR does well, mention any notable changes, and be encouraging.")
  table.insert(parts, "Output the summary in a ```markdown code block.")

  return table.concat(parts, "\n")
end

--- Extract the review summary from AI output.
--- Tries ```markdown block first, then generic code block, then falls back to trimmed output.
--- @param output string
--- @return string
function M.parse_review_summary(output)
  if not output or output == "" then return "" end

  -- Try ```markdown block first
  local markdown_content = output:match("```markdown%s*\n(.-)\n```")
  if markdown_content then
    return vim.trim(markdown_content)
  end

  -- Try generic code block
  local code_content = output:match("```[%w]*%s*\n(.-)\n```")
  if code_content then
    return vim.trim(code_content)
  end

  -- Fallback to trimmed output
  return vim.trim(output)
end

--- Generate a review summary using the AI subprocess.
--- @param review { title: string, description: string }
--- @param diffs { new_path?: string, old_path?: string, diff?: string }[]
--- @param suggestions { status: string, comment: string, severity: string }[]
--- @param callback fun(summary: string|nil, err: string|nil)
function M.generate(review, diffs, suggestions, callback)
  local provider = require("codereview.ai.providers").get()
  local prompt = M.build_review_summary_prompt(review, diffs, suggestions)
  provider.run(prompt, function(output, err)
    if err then
      callback(nil, err)
      return
    end
    callback(M.parse_review_summary(output or ""))
  end, { skip_agent = true })
end

return M
