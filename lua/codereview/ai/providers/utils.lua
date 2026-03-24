local log = require("codereview.log")
local M = {}

---Run a CLI command asynchronously, sending the prompt via stdin and collecting output.
---@param prompt string|string[] prompt that will be passed to the AI
---@param callback fun(string?, string?) callback that takes either the AI output as first argument or an error message as second argument.
---@param cmd string[] command to execute that consumes the prompt input to produce an output passed to the callback.
---@return integer Returns |job-id| on success, 0 on invalid arguments (or job table is full), -1 if {cmd}[0] or 'shell' is not executable.
function M.run_cli(prompt, callback, cmd)
  log.debug("AI cmd: starting " .. table.concat(cmd, " "))
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
      if done then
        return
      end
      done = true
      vim.schedule(function()
        local stderr_str = table.concat(stderr_chunks, "\n")
        if stderr_str ~= "" then
          log.warn("AI cmd stderr: " .. stderr_str)
        end
        local output = table.concat(stdout_chunks, "\n")
        if code ~= 0 then
          local msg = "Command exited with code " .. code
          if output ~= "" then
            msg = msg .. "\n" .. output
          end
          if stderr_str ~= "" then
            msg = msg .. "\n" .. stderr_str
          end
          log.error("AI cmd: " .. msg)
          callback(nil, msg)
        else
          log.debug("AI cmd: completed, output length=" .. #output)
          callback(output)
        end
      end)
    end,
  })

  if job_id <= 0 then
    local msg = "Failed to start '" .. table.concat(cmd, " ") .. "'. Is it in your PATH?"
    log.error("AI cmd: " .. msg)
    callback(nil, msg)
    return job_id
  end

  vim.fn.chansend(job_id, prompt)
  vim.fn.chanclose(job_id, "stdin")
  return job_id
end

return M
