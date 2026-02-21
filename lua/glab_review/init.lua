local M = {}

function M.setup(opts)
  require("glab_review.config").setup(opts)
end

-- Stubs for later stages
function M.open() vim.notify("MR picker not yet implemented (Stage 2)", vim.log.levels.WARN) end
function M.pipeline() vim.notify("Pipeline not yet implemented (Stage 4)", vim.log.levels.WARN) end
function M.ai_review() vim.notify("AI review not yet implemented (Stage 5)", vim.log.levels.WARN) end
function M.submit() vim.notify("Submit not yet implemented (Stage 5)", vim.log.levels.WARN) end
function M.approve() vim.notify("Approve not yet implemented (Stage 3)", vim.log.levels.WARN) end
function M.create_mr() vim.notify("Create MR not yet implemented (Stage 5)", vim.log.levels.WARN) end

return M
