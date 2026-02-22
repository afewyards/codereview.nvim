local M = {}

function M.setup()
  vim.api.nvim_set_hl(0, "GlabReviewDiffAdd", { bg = "#2a4a2a", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewDiffDelete", { bg = "#4a2a2a", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewDiffAddWord", { bg = "#3a6a3a", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewDiffDeleteWord", { bg = "#6a3a3a", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewComment", { bg = "#2a2a3a", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewCommentUnresolved", { bg = "#3a2a2a", fg = "#ff9966", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewFileChanged", { fg = "#e0af68", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewFileAdded", { fg = "#9ece6a", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewFileDeleted", { fg = "#f7768e", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewHidden", { fg = "#565f89", italic = true, default = true })
  vim.api.nvim_set_hl(0, "GlabReviewCommentBorder", { fg = "#565f89", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewCommentAuthor", { fg = "#7aa2f7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "GlabReviewCommentResolved", { fg = "#9ece6a", default = true })
  vim.fn.sign_define("GlabReviewCommentSign", { text = "▍ ", texthl = "GlabReviewComment" })
  vim.fn.sign_define("GlabReviewUnresolvedSign", { text = "▍ ", texthl = "GlabReviewCommentUnresolved" })
end

return M
