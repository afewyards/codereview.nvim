local M = {}

function M.setup()
  vim.api.nvim_set_hl(0, "CodeReviewDiffAdd", { bg = "#2a4a2a", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewDiffDelete", { bg = "#4a2a2a", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewDiffAddWord", { bg = "#3a6a3a", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewDiffDeleteWord", { bg = "#6a3a3a", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewComment", { bg = "#2a2a3a", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewCommentUnresolved", { bg = "#3a2a2a", fg = "#ff9966", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewFileChanged", { fg = "#e0af68", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewFileAdded", { fg = "#9ece6a", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewFileDeleted", { fg = "#f7768e", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewHidden", { fg = "#565f89", italic = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewCommentBorder", { fg = "#565f89", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewCommentAuthor", { fg = "#7aa2f7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewCommentResolved", { fg = "#9ece6a", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewAIDraft", { bg = "#2a2a3a", fg = "#bb9af7", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewAIDraftBorder", { fg = "#bb9af7", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewFileHeader", { bg = "#1e2030", fg = "#c8d3f5", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewLineNr", { fg = "#565f89", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewSummaryButton", { fg = "#7aa2f7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewSpinner", { fg = "#7aa2f7", bold = true, default = true })
  vim.fn.sign_define("CodeReviewCommentSign", { text = "▍ ", texthl = "CodeReviewComment" })
  vim.fn.sign_define("CodeReviewUnresolvedSign", { text = "▍ ", texthl = "CodeReviewCommentUnresolved" })
  vim.fn.sign_define("CodeReviewAISign", { text = "▍ ", texthl = "CodeReviewAIDraft" })
end

return M
