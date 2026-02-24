if vim.g.loaded_codereview then
  return
end
vim.g.loaded_codereview = true

vim.api.nvim_create_user_command("CodeReview", function()
  require("codereview").open()
end, { desc = "Open review picker" })

vim.api.nvim_create_user_command("CodeReviewPipeline", function()
  require("codereview").pipeline()
end, { desc = "Show pipeline for current review" })

vim.api.nvim_create_user_command("CodeReviewAI", function()
  require("codereview").ai_review()
end, { desc = "Run AI review on current review" })

vim.api.nvim_create_user_command("CodeReviewSubmit", function()
  require("codereview").submit()
end, { desc = "Submit draft comments" })

vim.api.nvim_create_user_command("CodeReviewApprove", function()
  require("codereview").approve()
end, { desc = "Approve current review" })

vim.api.nvim_create_user_command("CodeReviewOpen", function()
  require("codereview").create_mr()
end, { desc = "Create new review" })

vim.api.nvim_create_user_command("CodeReviewStart", function()
  require("codereview").start_review()
end, { desc = "Start manual review session (comments become drafts)" })

vim.api.nvim_create_user_command("CodeReviewComments", function()
  require("codereview").comments()
end, { desc = "Browse comments and suggestions" })

vim.api.nvim_create_user_command("CodeReviewFiles", function()
  require("codereview").files()
end, { desc = "Browse changed files" })
