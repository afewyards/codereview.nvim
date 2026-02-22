local providers = require("codereview.providers")
local M = {}

function M.approve(review)
  local provider, ctx, err = providers.detect()
  if not provider then return nil, err end
  local client = require("codereview.api.client")
  return provider.approve(client, ctx, review)
end

function M.unapprove(review)
  local provider, ctx, err = providers.detect()
  if not provider then return nil, err end
  local client = require("codereview.api.client")
  local result, unapprove_err = provider.unapprove(client, ctx, review)
  if unapprove_err then
    vim.notify(unapprove_err, vim.log.levels.WARN)
  end
  return result, unapprove_err
end

function M.merge(review, opts)
  local provider, ctx, err = providers.detect()
  if not provider then return nil, err end
  local client = require("codereview.api.client")
  return provider.merge(client, ctx, review, opts)
end

function M.close(review)
  local provider, ctx, err = providers.detect()
  if not provider then return nil, err end
  local client = require("codereview.api.client")
  return provider.close(client, ctx, review)
end

return M
