local config = require("codereview.config")
local utils = require("codereview.ai.providers.utils")
local M = {}

function M.build_cmd(cmd, args)
  local t = { cmd }
  for _, arg in ipairs(args or {}) do
    table.insert(t, arg)
  end
  return t
end

function M.run(prompt, callback)
  local cfg = config.get()
  if not cfg.ai.enabled then
    callback(nil, "AI review is disabled in config")
    return
  end

  local pcfg = cfg.ai.custom_cmd or {}
  if not pcfg.cmd or pcfg.cmd == "" then
    callback(nil, "Custom command not configured (set ai.custom_cmd.cmd)")
    return
  end

  local cmd = M.build_cmd(pcfg.cmd, pcfg.args)
  return utils.run_cli(prompt, callback, cmd)
end

return M
