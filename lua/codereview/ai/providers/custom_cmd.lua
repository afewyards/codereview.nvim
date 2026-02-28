local config = require("codereview.config")
local log = require("codereview.log")
local M = {}

function M.build_cmd(cmd, args)
  local t = { cmd }
  for _, arg in ipairs(args or {}) do
    table.insert(t, arg)
  end
  return t
end

function M.run(prompt, callback, opts)
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
  log.debug("AI custom_cmd: starting " .. table.concat(cmd, " "))
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
          log.warn("AI custom_cmd stderr: " .. stderr_str)
        end
        local output = table.concat(stdout_chunks, "\n")
        if code ~= 0 then
          local msg = "Custom command exited with code " .. code
          if output ~= "" then msg = msg .. "\n" .. output end
          if stderr_str ~= "" then msg = msg .. "\n" .. stderr_str end
          log.error("AI custom_cmd: " .. msg)
          callback(nil, msg)
        else
          log.debug("AI custom_cmd: completed, output length=" .. #output)
          callback(output)
        end
      end)
    end,
  })

  if job_id <= 0 then
    local msg = "Failed to start '" .. pcfg.cmd .. "'. Is it in your PATH?"
    log.error("AI custom_cmd: " .. msg)
    callback(nil, msg)
    return
  end

  vim.fn.chansend(job_id, prompt)
  vim.fn.chanclose(job_id, "stdin")
  return job_id
end

return M
