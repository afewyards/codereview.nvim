local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
if vim.fn.isdirectory(plenary_dir) == 0 then
  vim.fn.system({ "git", "clone", "https://github.com/nvim-lua/plenary.nvim", plenary_dir })
end
vim.opt.runtimepath:append(".")
vim.opt.runtimepath:append(plenary_dir)
vim.cmd("runtime plugin/plenary.vim")
