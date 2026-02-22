local M = {}

function M.setup(opts)
  require("glab_review.config").setup(opts)
  require("glab_review.ui.highlight").setup()
  vim.api.nvim_create_autocmd("ColorScheme", {
    callback = function()
      require("glab_review.ui.highlight").setup()
    end,
  })
end

-- Stubs for later stages
function M.open()
  local mr_list = require("glab_review.mr.list")
  local picker = require("glab_review.picker")
  local detail = require("glab_review.mr.detail")

  mr_list.fetch({}, function(entries, err)
    if err then
      vim.notify("Failed to load MRs: " .. err, vim.log.levels.ERROR)
      return
    end
    if not entries or #entries == 0 then
      vim.notify("No open merge requests found", vim.log.levels.INFO)
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
function M.approve() vim.notify("Approve not yet implemented (Stage 3)", vim.log.levels.WARN) end
function M.create_mr() vim.notify("Create MR not yet implemented (Stage 5)", vim.log.levels.WARN) end

return M
