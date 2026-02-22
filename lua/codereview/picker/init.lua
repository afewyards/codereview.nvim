local config = require("codereview.config")
local M = {}

local adapters = {
  telescope = "codereview.picker.telescope",
  fzf = "codereview.picker.fzf",
  snacks = "codereview.picker.snacks",
}

function M.detect()
  local cfg = config.get()
  if cfg.picker and adapters[cfg.picker] then
    return cfg.picker
  end

  local ok
  ok, _ = pcall(require, "telescope")
  if ok then return "telescope" end

  ok, _ = pcall(require, "fzf-lua")
  if ok then return "fzf" end

  ok, _ = pcall(require, "snacks")
  if ok then return "snacks" end

  return nil
end

function M.get_adapter(name)
  local mod_path = adapters[name]
  if not mod_path then
    error("Unknown picker: " .. tostring(name) .. ". Use telescope, fzf, or snacks.")
  end
  return require(mod_path)
end

function M.pick_mr(entries, on_select)
  local name = M.detect()
  if not name then
    vim.notify("No picker found. Install telescope.nvim, fzf-lua, or snacks.nvim", vim.log.levels.ERROR)
    return
  end

  local adapter = M.get_adapter(name)
  adapter.pick_mr(entries, on_select)
end

return M
