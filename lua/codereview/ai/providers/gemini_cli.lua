local config = require("codereview.config")
local utils = require("codereview.ai.providers.utils")
local M = {}

function M.build_cmd(gemini_cmd, model)
  local cmd = { gemini_cmd or "gemini" }
  table.insert(cmd, "--approval-mode=plan")
  if model and model ~= "" then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end
  return cmd
end

function M.run(prompt, callback)
  local cfg = config.get()
  if not cfg.ai.enabled then
    callback(nil, "AI review is disabled in config")
    return
  end

  local pcfg = cfg.ai.gemini_cli or {}
  local cmd = M.build_cmd(pcfg.cmd, pcfg.model)
  return utils.run_cli(prompt, callback, cmd)
end

return M
