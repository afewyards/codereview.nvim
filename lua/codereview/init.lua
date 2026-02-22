local M = {}

function M.setup(opts)
  require("codereview.config").setup(opts)
  require("codereview.ui.highlight").setup()
  vim.api.nvim_create_autocmd("ColorScheme", {
    callback = function()
      require("codereview.ui.highlight").setup()
    end,
  })
end

-- Stubs for later stages
function M.open()
  local mr_list = require("codereview.mr.list")
  local picker = require("codereview.picker")
  local detail = require("codereview.mr.detail")

  mr_list.fetch({}, function(entries, err)
    if err then
      vim.notify("Failed to load reviews: " .. err, vim.log.levels.ERROR)
      return
    end
    if not entries or #entries == 0 then
      vim.notify("No open reviews found", vim.log.levels.INFO)
      return
    end

    vim.schedule(function()
      picker.pick_mr(entries, function(selected)
        detail.open(selected)
      end)
    end)
  end)
end
function M.pipeline() vim.notify("Pipeline not yet implemented (Stage 4)", vim.log.levels.WARN) end
function M.ai_review() vim.notify("AI review not yet implemented (Stage 5)", vim.log.levels.WARN) end
function M.submit() vim.notify("Submit not yet implemented (Stage 5)", vim.log.levels.WARN) end
function M.approve()
  local buf = vim.api.nvim_get_current_buf()
  local mr = vim.b[buf].codereview_review
  if not mr then
    vim.notify("No review context in current buffer", vim.log.levels.WARN)
    return
  end
  require("codereview.mr.actions").approve(mr)
end
function M.create_mr()
  require("codereview.mr.create").create()
end

return M
