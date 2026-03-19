--- Transport abstraction for HTTP requests.
--- Supports two backends: "curl" (plenary.curl) and "gh" (GitHub CLI).
--- Auto-detection tries gh first (if installed and authed for GitHub),
--- then falls back to curl with token auth.
local log = require("codereview.log")

local M = {}

local _detected_transport = nil

local function gh_is_available()
  local output = vim.fn.system({ "gh", "auth", "status" })
  return output:find("Logged in to github.com") ~= nil
end

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

  local stdin = opts.body and vim.json.encode(opts.body) or nil
  local result = vim.fn.system(args, stdin)
  if vim.v.shell_error ~= 0 and result:match("^gh:") then
    return nil, result
  end

  -- Split headers from body on the first blank line
  local header_block, body = result:match("^(.-)\n\r?\n(.*)$")
  if not header_block then
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

function M.gh_graphql(query, variables)
  local payload = vim.json.encode({ query = query, variables = variables or {} })

  log.debug("GH GraphQL request")

  local result = vim.fn.system({ "gh", "api", "graphql", "--input", "-" }, payload)
  if vim.v.shell_error ~= 0 then
    return nil, "gh graphql failed: " .. result
  end

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

function M.gh_download_text(path)
  local result = vim.fn.system({ "gh", "api", path })
  if vim.v.shell_error ~= 0 then
    return nil, "gh download failed: " .. result
  end
  if result == "" then
    return nil, "Empty response from gh"
  end
  return result
end

function M.reset()
  _detected_transport = nil
end

return M
