-- demo/init.lua — Minimal Neovim config for VHS showcase recordings
-- Run: nvim -u demo/init.lua

-- Paths
local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local demo_dir = repo_root .. "/demo"
local deps_dir = demo_dir .. "/.deps"

-- Bootstrap dependencies (first run only)
local function ensure_dep(name, url)
	local path = deps_dir .. "/" .. name
	if not vim.loop.fs_stat(path) then
		print("Downloading " .. name .. "...")
		vim.fn.system({ "git", "clone", "--depth", "1", url, path })
	end
	vim.opt.runtimepath:prepend(path)
end

ensure_dep("plenary.nvim", "https://github.com/nvim-lua/plenary.nvim")
ensure_dep("telescope.nvim", "https://github.com/nvim-telescope/telescope.nvim")
ensure_dep("gruvbox-material", "https://github.com/sainnhe/gruvbox-material")
ensure_dep("screenkey", "https://github.com/NStefan002/screenkey.nvim")
ensure_dep("nvim-notify", "https://github.com/rcarriga/nvim-notify")

-- Add main plugin + demo provider to runtimepath
vim.opt.runtimepath:prepend(repo_root)
vim.opt.runtimepath:prepend(demo_dir)

-- UI settings for recording
vim.o.termguicolors = true
vim.o.background = "dark"
vim.o.number = true
vim.o.relativenumber = false
vim.o.signcolumn = "yes"
vim.o.laststatus = 2
vim.o.cmdheight = 1

-- Theme
vim.g.gruvbox_material_background = "soft"
vim.g.gruvbox_material_enable_italic = 1
vim.cmd([[ colorscheme gruvbox-material ]])

-- Monkey-patch provider detection to skip git/network
local providers = require("codereview.providers")
providers.detect = function()
	local demo_provider = require("codereview.providers.demo")
	return demo_provider,
		{
			base_url = "https://demo.local",
			project = "acme/api-server",
			host = "demo.local",
			platform = "demo",
		},
		nil
end

-- Configure plugin
require("codereview").setup({
	platform = "demo",
	base_url = "https://demo.local",
	project = "acme/api-server",
	picker = "telescope",
	ai = {
		enabled = true,
		provider = "claude_cli",
		claude_cli = {
			cmd = demo_dir .. "/mock-claude",
		},
	},
})

vim.notify = require("notify")

require("screenkey").setup({
	win_opts = {
		row = vim.o.lines - vim.o.cmdheight - 1,
		col = 1,
		relative = "editor",
		anchor = "SW",
		width = 28,
	},
	group_mappings = true,
})
vim.defer_fn(function()
	require("screenkey").toggle()
end, 1500)
