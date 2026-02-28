local log = require("codereview.log")
local M = {}

function M.build_curl_cmd(url, headers, body)
  local cmd = { "curl", "-sS", "-X", "POST" }
  for k, v in pairs(headers or {}) do
    table.insert(cmd, "-H")
    table.insert(cmd, k .. ": " .. v)
  end
  table.insert(cmd, "-d")
  table.insert(cmd, body)
  table.insert(cmd, url)
  return cmd
end

--- POST JSON to a URL, parse response, call callback with body table.
--- @param url string
--- @param headers table<string,string>
--- @param body_table table  Will be JSON-encoded
--- @param callback fun(response: table|nil, err: string|nil)
--- @return number|nil job_id
function M.post_json(url, headers, body_table, callback)
  headers = headers or {}
  headers["Content-Type"] = "application/json"

  local body = vim.json.encode(body_table)
  local cmd = M.build_curl_cmd(url, headers, body)
  log.debug("AI http: POST " .. url)

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
        local output = table.concat(stdout_chunks, "\n")

        if code ~= 0 then
          local msg = "HTTP request failed (exit " .. code .. ")"
          if stderr_str ~= "" then msg = msg .. ": " .. stderr_str end
          log.error("AI http: " .. msg)
          callback(nil, msg)
          return
        end

        local ok, data = pcall(vim.json.decode, output)
        if not ok then
          log.error("AI http: JSON decode failed: " .. tostring(data))
          callback(nil, "Invalid JSON response from API")
          return
        end

        if type(data) == "table" and data.error then
          local err_msg = type(data.error) == "table" and (data.error.message or vim.json.encode(data.error)) or tostring(data.error)
          log.error("AI http: API error: " .. err_msg)
          callback(nil, "API error: " .. err_msg)
          return
        end

        callback(data)
      end)
    end,
  })

  if job_id <= 0 then
    local msg = "Failed to start curl. Is curl in your PATH?"
    log.error("AI http: " .. msg)
    callback(nil, msg)
    return
  end

  return job_id
end

return M
