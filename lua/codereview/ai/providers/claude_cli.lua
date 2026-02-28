local config = require("codereview.config")
local log = require("codereview.log")
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
  log.debug("AI claude_cli: starting " .. table.concat(cmd, " "))
  local stdout_chunks = {}
  local stderr_chunks = {}
  local done = false

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for i, chunk in ipairs(data) do
          if i < #data or chunk ~= "" then
            table.insert(stdout_chunks, chunk)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for i, chunk in ipairs(data) do
          if i < #data or chunk ~= "" then
            table.insert(stderr_chunks, chunk)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if done then return end
      done = true
      vim.schedule(function()
        local stderr_str = table.concat(stderr_chunks, "\n")
        if stderr_str ~= "" then
          log.warn("AI claude_cli stderr: " .. stderr_str)
        end
        local output = table.concat(stdout_chunks, "\n")
        if code ~= 0 then
          local msg = "Claude CLI exited with code " .. code
          if output ~= "" then msg = msg .. "\n" .. output end
          if stderr_str ~= "" then msg = msg .. "\n" .. stderr_str end
          log.error("AI claude_cli: " .. msg)
          callback(nil, msg)
        else
          log.debug("AI claude_cli: completed, output length=" .. #output)
          callback(output)
        end
      end)
    end,
  })

  if job_id <= 0 then
    local msg = "Failed to start Claude CLI. Is '" .. claude_cmd .. "' in your PATH?"
    log.error("AI claude_cli: " .. msg)
    callback(nil, msg)
    return
  end

  vim.fn.chansend(job_id, prompt)
  vim.fn.chanclose(job_id, "stdin")
  return job_id
end

return M
