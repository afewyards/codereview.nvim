if vim.g.loaded_glab_review then
  return
end
vim.g.loaded_glab_review = true

vim.api.nvim_create_user_command("GlabReview", function()
  require("glab_review").open()
end, { desc = "Open MR picker" })

vim.api.nvim_create_user_command("GlabReviewPipeline", function()
  require("glab_review").pipeline()
end, { desc = "Show pipeline for current MR" })

vim.api.nvim_create_user_command("GlabReviewAI", function()
  require("glab_review").ai_review()
end, { desc = "Run AI review on current MR" })

vim.api.nvim_create_user_command("GlabReviewSubmit", function()
  require("glab_review").submit()
end, { desc = "Submit draft comments" })

vim.api.nvim_create_user_command("GlabReviewApprove", function()
  require("glab_review").approve()
end, { desc = "Approve current MR" })

vim.api.nvim_create_user_command("GlabReviewOpen", function()
  require("glab_review").create_mr()
end, { desc = "Create new MR" })
