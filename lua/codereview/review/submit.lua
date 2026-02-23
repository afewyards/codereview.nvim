-- lua/codereview/review/submit.lua
local providers = require("codereview.providers")
local client = require("codereview.api.client")
local M = {}

function M.filter_accepted(suggestions)
  local accepted = {}
  for _, s in ipairs(suggestions) do
    if (s.status == "accepted" or s.status == "edited") and not s.drafted then
      table.insert(accepted, s)
    end
  end
  return accepted
end

function M.submit_review(review, suggestions)
  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify("Could not detect platform: " .. (err or ""), vim.log.levels.ERROR)
    return false
  end

  local accepted = M.filter_accepted(suggestions)
  if #accepted == 0 then
    vim.notify("No accepted suggestions to submit", vim.log.levels.WARN)
    return false
  end

  local errors = {}
  for _, suggestion in ipairs(accepted) do
    local _, post_err = provider.create_draft_comment(client, ctx, review, {
      body = suggestion.comment,
      path = suggestion.file,
      line = suggestion.line,
    })
    if post_err then
      table.insert(errors, string.format("%s:%d - %s", suggestion.file, suggestion.line, post_err))
    else
      suggestion.drafted = true
    end
  end

  local _, pub_err = provider.publish_review(client, ctx, review)
  if pub_err then
    table.insert(errors, "Publish failed: " .. pub_err)
  end

  if #errors > 0 then
    vim.notify("Some drafts failed:\n" .. table.concat(errors, "\n"), vim.log.levels.WARN)
  else
    vim.notify(string.format("Review submitted: %d comments", #accepted), vim.log.levels.INFO)
  end

  return #errors == 0
end

function M.submit_and_publish(review, ai_suggestions)
  -- Post remaining accepted AI suggestions as drafts
  if ai_suggestions then
    local remaining = M.filter_accepted(ai_suggestions)
    if #remaining > 0 then
      M.submit_review(review, ai_suggestions)
    end
  end
  -- Publish all drafts (human + AI)
  M.bulk_publish(review)
  -- Dismiss all AI suggestions
  if ai_suggestions then
    for _, s in ipairs(ai_suggestions) do s.status = "dismissed" end
  end
end

function M.bulk_publish(review)
  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify("Could not detect platform: " .. (err or ""), vim.log.levels.ERROR)
    return false
  end
  local _, pub_err = provider.publish_review(client, ctx, review)
  if pub_err then
    vim.notify("Failed to publish: " .. pub_err, vim.log.levels.ERROR)
    return false
  end
  vim.notify("Review published!", vim.log.levels.INFO)
  return true
end

return M
