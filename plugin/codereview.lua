if vim.g.loaded_codereview then
  return
end
vim.g.loaded_codereview = true

vim.api.nvim_create_user_command("CodeReview", function()
  require("codereview").open()
end, { desc = "Open MR picker" })

vim.api.nvim_create_user_command("CodeReviewPipeline", function()
  require("codereview").pipeline()
end, { desc = "Show pipeline for current MR" })

vim.api.nvim_create_user_command("CodeReviewAI", function()
  require("codereview").ai_review()
end, { desc = "Run AI review on current MR" })

vim.api.nvim_create_user_command("CodeReviewSubmit", function()
  require("codereview").submit()
end, { desc = "Submit draft comments" })

vim.api.nvim_create_user_command("CodeReviewApprove", function()
  require("codereview").approve()
end, { desc = "Approve current MR" })

vim.api.nvim_create_user_command("CodeReviewOpen", function()
  require("codereview").create_mr()
end, { desc = "Create new MR" })
