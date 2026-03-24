local config = require("codereview.config")
local utils = require("codereview.ai.providers.utils")
local M = {}

function M.build_cmd(copilot_cmd, model, agent)
  local cmd = { copilot_cmd or "copilot" }
  table.insert(cmd, "--silent")
  table.insert(cmd, "--no-auto-update")
  if model and model ~= "" then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end
  if agent and agent ~= "" then
    table.insert(cmd, "--agent")
    table.insert(cmd, agent)
  end
  return cmd
end

function M.run(prompt, callback)
  local cfg = config.get()
  if not cfg.ai.enabled then
    callback(nil, "AI review is disabled in config")
    return
  end

  local pcfg = cfg.ai.copilot_cli or {}
  local cmd = M.build_cmd(pcfg.cmd, pcfg.model, pcfg.agent)
  return utils.run_cli(prompt, callback, cmd)
end

return M
