local config = require("codereview.config")
local utils = require("codereview.ai.providers.utils")
local M = {}

function M.build_cmd(qwen_cmd, model)
  local cmd = { qwen_cmd or "qwen" }
  table.insert(cmd, "--approval-mode=plan")
  if model then
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

  local pcfg = cfg.ai.qwen_cli or {}
  local cmd = M.build_cmd(pcfg.cmd, pcfg.model)
  return utils.run_cli(prompt, callback, cmd)
end

return M
