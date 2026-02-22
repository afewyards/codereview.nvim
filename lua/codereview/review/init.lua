-- lua/codereview/review/init.lua
local providers = require("codereview.providers")
local client = require("codereview.api.client")
local ai_sub = require("codereview.ai.subprocess")
local prompt_mod = require("codereview.ai.prompt")
local triage = require("codereview.review.triage")
local M = {}

function M.start(review)
  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify("Could not detect platform: " .. (err or ""), vim.log.levels.ERROR)
    return
  end

  -- Fetch diffs
  local diffs, diffs_err = provider.get_diffs(client, ctx, review)
  if not diffs or #diffs == 0 then
    vim.notify("No diffs found: " .. (diffs_err or ""), vim.log.levels.WARN)
    return
  end

  -- Fetch discussions
  local discussions = provider.get_discussions(client, ctx, review) or {}

  -- Run Claude review
  local review_prompt = prompt_mod.build_review_prompt(review, diffs)
  vim.notify("Running AI review...", vim.log.levels.INFO)

  ai_sub.run(review_prompt, function(output, ai_err)
    if ai_err then
      vim.notify("AI review failed: " .. ai_err, vim.log.levels.ERROR)
      return
    end

    local suggestions = prompt_mod.parse_review_output(output)
    if #suggestions == 0 then
      vim.notify("AI review: no issues found!", vim.log.levels.INFO)
      return
    end

    vim.notify(string.format("AI review: %d suggestions found", #suggestions), vim.log.levels.INFO)
    triage.open(review, diffs, discussions, suggestions)
  end)
end

return M
