local providers = require("codereview.providers")
local M = {}

function M.approve(review)
  require("plenary.async").run(function()
    local async_client = require("codereview.api.async_client")
    local provider, ctx, err = providers.detect()
    if not provider then
      vim.schedule(function()
        vim.notify(err or "Could not detect platform", vim.log.levels.ERROR)
      end)
      return
    end
    local result, approve_err = provider.approve(async_client, ctx, review)
    vim.schedule(function()
      if approve_err then
        vim.notify("Approve failed: " .. approve_err, vim.log.levels.ERROR)
      elseif result then
        vim.notify("Review approved", vim.log.levels.INFO)
      end
    end)
  end)
end

function M.unapprove(review)
  require("plenary.async").run(function()
    local async_client = require("codereview.api.async_client")
    local provider, ctx, err = providers.detect()
    if not provider then
      vim.schedule(function()
        vim.notify(err or "Could not detect platform", vim.log.levels.ERROR)
      end)
      return
    end
    local _, unapprove_err = provider.unapprove(async_client, ctx, review)
    if unapprove_err then
      vim.schedule(function()
        vim.notify(unapprove_err, vim.log.levels.WARN)
      end)
    end
  end)
end

function M.merge(review, opts)
  require("plenary.async").run(function()
    local async_client = require("codereview.api.async_client")
    local provider, ctx, err = providers.detect()
    if not provider then
      vim.schedule(function()
        vim.notify(err or "Could not detect platform", vim.log.levels.ERROR)
      end)
      return
    end
    local result, merge_err = provider.merge(async_client, ctx, review, opts)
    vim.schedule(function()
      if merge_err then
        vim.notify("Merge failed: " .. merge_err, vim.log.levels.ERROR)
      elseif result then
        vim.notify("Merge successful", vim.log.levels.INFO)
      end
    end)
  end)
end

function M.close(review)
  require("plenary.async").run(function()
    local async_client = require("codereview.api.async_client")
    local provider, ctx, err = providers.detect()
    if not provider then
      vim.schedule(function()
        vim.notify(err or "Could not detect platform", vim.log.levels.ERROR)
      end)
      return
    end
    local result, close_err = provider.close(async_client, ctx, review)
    vim.schedule(function()
      if close_err then
        vim.notify("Close failed: " .. close_err, vim.log.levels.ERROR)
      elseif result then
        vim.notify("Review closed", vim.log.levels.INFO)
      end
    end)
  end)
end

return M
