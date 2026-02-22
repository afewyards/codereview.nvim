-- lua/codereview/ai/subprocess.lua
local config = require("codereview.config")
local M = {}

function M.build_cmd(claude_cmd)
  return { claude_cmd, "-p", "--output-format", "json", "--max-turns", "1" }
end

function M.run(prompt, callback)
  local cfg = config.get()
  if not cfg.ai.enabled then
    callback(nil, "AI review is disabled in config")
    return
  end

  local cmd = M.build_cmd(cfg.ai.claude_cmd)
  local stdout_chunks = {}
  local done = false

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          if chunk ~= "" then table.insert(stdout_chunks, chunk) end
        end
      end
    end,
    on_exit = function(_, code)
      if done then return end
      done = true
      vim.schedule(function()
        if code ~= 0 then
          callback(nil, "Claude CLI exited with code " .. code)
        else
          callback(table.concat(stdout_chunks, "\n"))
        end
      end)
    end,
  })

  if job_id <= 0 then
    callback(nil, "Failed to start Claude CLI. Is '" .. cfg.ai.claude_cmd .. "' in your PATH?")
    return
  end

  vim.fn.chansend(job_id, prompt)
  vim.fn.chanclose(job_id, "stdin")
end

return M
