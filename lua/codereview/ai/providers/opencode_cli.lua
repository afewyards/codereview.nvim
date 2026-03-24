local config = require("codereview.config")
local utils = require("codereview.ai.providers.utils")
local M = {}

function M.build_cmd(opencode_cmd, model, agent, variant)
  local cmd = { opencode_cmd or "opencode", "run" }
  if model and model ~= "" then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end
  if agent and agent ~= "" then
    table.insert(cmd, "--agent")
    table.insert(cmd, agent)
  end
  if variant and variant ~= "" then
    table.insert(cmd, "--variant")
    table.insert(cmd, variant)
  end
  table.insert(cmd, "--")
  return cmd
end

function M.run(prompt, callback)
  local cfg = config.get()
  if not cfg.ai.enabled then
    callback(nil, "AI review is disabled in config")
    return
  end

  local pcfg = cfg.ai.opencode_cli or {}
  local cmd = M.build_cmd(pcfg.cmd, pcfg.model, pcfg.agent, pcfg.variant)
  return utils.run_cli(prompt, callback, cmd)
end

return M
