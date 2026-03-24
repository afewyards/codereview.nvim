local config = require("codereview.config")
local utils = require("codereview.ai.providers.utils")
local M = {}

function M.build_cmd(claude_cmd, agent)
  local cmd = { claude_cmd, "-p" }
  if agent then
    table.insert(cmd, "--agent")
    table.insert(cmd, agent)
  end
  return cmd
end

function M.run(prompt, callback, opts)
  opts = opts or {}
  local cfg = config.get()
  if not cfg.ai.enabled then
    callback(nil, "AI review is disabled in config")
    return
  end

  local pcfg = cfg.ai.claude_cli or {}
  local claude_cmd = pcfg.cmd or cfg.ai.claude_cmd or "claude"
  local agent = (not opts.skip_agent) and (pcfg.agent or cfg.ai.agent) or nil
  local cmd = M.build_cmd(claude_cmd, agent)
  return utils.run_cli(prompt, callback, cmd)
end

return M
