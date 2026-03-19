--- Transport abstraction for HTTP requests.
--- Supports two backends: "curl" (plenary.curl) and "gh" (GitHub CLI).
--- Auto-detection tries gh first (if installed and authed for GitHub),
--- then falls back to curl with token auth.
local log = require("codereview.log")

local M = {}

local _detected_transport = nil

--- Check if gh CLI is available and authenticated for GitHub.
--- @return boolean
local function gh_is_available()
  local handle = io.popen("gh auth status 2>&1")
  if not handle then
    return false
  end
  local output = handle:read("*a")
  handle:close()
  return output:find("Logged in to github.com") ~= nil
end

--- Resolve the active transport for a given platform.
--- @param platform string "github" | "gitlab"
--- @return string "gh" | "curl"
function M.resolve(platform)
  local config = require("codereview.config").get()
  local configured = config.transport

  if configured == "gh" then
    return "gh"
  elseif configured == "curl" then
    return "curl"
  end

  -- auto-detect: gh only works for GitHub
  if platform ~= "github" then
    return "curl"
  end

  if _detected_transport then
    return _detected_transport
  end

  if gh_is_available() then
    log.info("transport: auto-detected gh CLI")
    _detected_transport = "gh"
  else
    log.info("transport: gh CLI not available, using curl")
    _detected_transport = "curl"
  end
  return _detected_transport
end

--- Execute a request via gh CLI.
--- gh api handles auth, base URL, and JSON parsing automatically.
--- @param method string HTTP method (get, post, put, delete, patch)
--- @param base_url string API base URL (used to extract path for gh)
--- @param path string API path (e.g. "/repos/owner/repo/pulls")
--- @param opts table { body?, query?, headers? }
--- @return table|nil response { data, status, headers, next_page, next_url }
--- @return string|nil error
function M.gh_request(method, base_url, path, opts)
  opts = opts or {}

  local args = { "gh", "api", path, "--method", method:upper() }

  if opts.query then
    for k, v in pairs(opts.query) do
      table.insert(args, "-f")
      table.insert(args, k .. "=" .. tostring(v))
    end
  end

  if opts.body then
    table.insert(args, "--input")
    table.insert(args, "-")
  end

  -- Skip auth headers — gh handles authentication
  if opts.headers then
    for k, v in pairs(opts.headers) do
      if k ~= "Authorization" and k ~= "PRIVATE-TOKEN" then
        table.insert(args, "-H")
        table.insert(args, k .. ": " .. v)
      end
    end
  end

  table.insert(args, "--include")

  log.debug(string.format("GH REQ %s %s", method:upper(), path))

  local cmd = table.concat(args, " ")
  local result
  if opts.body then
    local json_body = vim.json.encode(opts.body)
    local handle = io.popen("echo " .. vim.fn.shellescape(json_body) .. " | " .. cmd .. " 2>&1")
    if not handle then
      return nil, "Failed to execute gh command"
    end
    result = handle:read("*a")
    handle:close()
  else
    local handle = io.popen(cmd .. " 2>&1")
    if not handle then
      return nil, "Failed to execute gh command"
    end
    result = handle:read("*a")
    handle:close()
  end

  local header_block, body = result:match("^(.-)\r?\n\r?\n(.*)$")
  if not header_block then
    if result:match("^gh:") or result:match("error") then
      return nil, result
    end
    body = result
    header_block = ""
  end

  local status = 200
  local status_match = header_block:match("HTTP/%S+ (%d+)")
  if status_match then
    status = tonumber(status_match)
  end

  local headers = {}
  for line in header_block:gmatch("[^\r\n]+") do
    local k, v = line:match("^([^:]+):%s*(.+)")
    if k then
      headers[k:lower()] = v
    end
  end

  if status < 200 or status >= 300 then
    log.error(string.format("GH RES %d %s %s — %s", status, method:upper(), path, body or ""))
    return nil, string.format("HTTP %d: %s", status, body or "")
  end

  local data = nil
  if body and body ~= "" then
    local ok, decoded = pcall(vim.json.decode, body)
    if ok then
      data = decoded
    else
      data = body
    end
  end

  log.debug(string.format("GH RES %d %s %s", status, method:upper(), path))

  return {
    data = data,
    status = status,
    headers = headers,
    next_page = headers["x-next-page"] and tonumber(headers["x-next-page"]) or nil,
    next_url = M.parse_link_next(headers["link"]),
  }
end

function M.parse_link_next(link)
  if not link then
    return nil
  end
  return link:match('<([^>]+)>%s*;%s*rel="next"')
end

--- Execute a GraphQL request via gh CLI.
--- @param query string GraphQL query
--- @param variables table|nil GraphQL variables
--- @return table|nil data
--- @return string|nil error
function M.gh_graphql(query, variables)
  local args = { "gh", "api", "graphql" }

  local payload = vim.json.encode({ query = query, variables = variables or {} })

  log.debug("GH GraphQL request")

  local cmd = table.concat(args, " ") .. " --input -"
  local handle = io.popen("echo " .. vim.fn.shellescape(payload) .. " | " .. cmd .. " 2>&1")
  if not handle then
    return nil, "Failed to execute gh graphql command"
  end
  local result = handle:read("*a")
  handle:close()

  local ok, data = pcall(vim.json.decode, result)
  if not ok then
    return nil, "Failed to decode GraphQL response: " .. tostring(result)
  end

  if data.errors then
    local msgs = {}
    for _, e in ipairs(data.errors) do
      table.insert(msgs, e.message or tostring(e))
    end
    return nil, "GraphQL errors: " .. table.concat(msgs, "; ")
  end

  return data.data
end

--- Download text content following redirects via gh CLI.
--- Used for endpoints like GitHub Actions job logs that return 302.
--- @param path string API path
--- @return string|nil text
--- @return string|nil error
function M.gh_download_text(path)
  local handle = io.popen("gh api " .. vim.fn.shellescape(path) .. " 2>&1")
  if not handle then
    return nil, "Failed to execute gh command"
  end
  local text = handle:read("*a")
  handle:close()
  if text == "" then
    return nil, "Empty response from gh"
  end
  return text
end

function M.reset()
  _detected_transport = nil
end

return M
