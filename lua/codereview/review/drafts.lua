-- lua/codereview/review/drafts.lua
-- Detect and manage server-side draft comments (unpublished reviews).
local M = {}

--- Fetch server-side draft comments from the provider.
--- @return table[] list of is_draft discussion objects (empty if none)
function M.fetch_server_drafts(provider, client, ctx, review)
  if provider.name == "gitlab" then
    return provider.get_draft_notes(client, ctx, review) or {}
  elseif provider.name == "github" then
    return provider.get_pending_review_drafts(client, ctx, review) or {}
  end
  return {}
end

--- Delete all server-side drafts (discard flow).
function M.discard_server_drafts(provider, client, ctx, review, server_drafts)
  if provider.name == "gitlab" then
    for _, d in ipairs(server_drafts) do
      if d.server_draft_id then
        provider.delete_draft_note(client, ctx, review, d.server_draft_id)
      end
    end
  elseif provider.name == "github" then
    provider.discard_pending_review(client, ctx, review)
  end
end

--- Check for server drafts and prompt user. Calls on_done(drafts_or_nil) when resolved.
--- drafts_or_nil is the list of draft discussions if user chose Resume, or nil if Discard/none found.
function M.check_and_prompt(provider, client, ctx, review, on_done)
  local server_drafts = M.fetch_server_drafts(provider, client, ctx, review)
  if #server_drafts == 0 then
    on_done(nil)
    return
  end

  vim.ui.select({ "Resume", "Discard" }, {
    prompt = string.format("%d draft comment(s) from a previous review. Resume or discard?", #server_drafts),
  }, function(choice)
    if choice == "Resume" then
      on_done(server_drafts)
    elseif choice == "Discard" then
      M.discard_server_drafts(provider, client, ctx, review, server_drafts)
      on_done(nil)
    else
      -- User cancelled the prompt — leave drafts on server, don't enter session
      on_done(nil)
    end
  end)
end

return M
