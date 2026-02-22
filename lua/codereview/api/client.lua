local curl = require("plenary.curl")
local async = require("plenary.async")
local async_util = require("plenary.async.util")
local M = {}

local function build_headers(token, token_type)
  if token_type == "oauth" then
    return {
      ["Authorization"] = "Bearer " .. token,
      ["Content-Type"] = "application/json",
    }
  else
    return {
      ["PRIVATE-TOKEN"] = token,
      ["Content-Type"] = "application/json",
    }
  end
end

local function parse_next_page(headers)
  local next_page = headers and headers["x-next-page"]
  if next_page and next_page ~= "" then
    return tonumber(next_page)
  end
  return nil
end

function M.parse_next_url(headers)
  local link = headers and (headers["link"] or headers["Link"])
  if not link then return nil end
  return link:match('<([^>]+)>%s*;%s*rel="next"')
end

function M.build_url(base_url, path)
  return base_url .. path
end

local function build_params(method, base_url, path, opts)
  local url = M.build_url(base_url, path)
  local params = {
    url = url,
    headers = opts.headers or {},
    method = method,
  }

  if opts.body then
    params.body = vim.json.encode(opts.body)
  end

  if opts.query then
    local parts = {}
    for k, v in pairs(opts.query) do
      table.insert(parts, k .. "=" .. vim.uri_encode(tostring(v)))
    end
    if #parts > 0 then
      params.url = params.url .. "?" .. table.concat(parts, "&")
    end
  end

  return params
end

local function process_response(response)
  local body = nil
  if response.body and response.body ~= "" then
    local ok, decoded = pcall(vim.json.decode, response.body)
    if ok then
      body = decoded
    else
      body = response.body
    end
  end

  return {
    data = body,
    status = response.status,
    headers = response.headers,
    next_page = parse_next_page(response.headers),
    next_url = M.parse_next_url(response.headers),
  }
end

function M.request(method, base_url, path, opts)
  opts = opts or {}

  -- Fall back to token auth if no headers provided (legacy support)
  if not opts.headers then
    local auth = require("codereview.api.auth")
    local token, token_type = auth.get_token()
    if not token then
      return nil, "No authentication token. Run :CodeReviewAuth"
    end
    opts = vim.tbl_extend("keep", opts, { headers = build_headers(token, token_type) })
  end

  local params = build_params(method, base_url, path, opts)

  local response = curl.request(params)
  if not response then
    return nil, "Request failed: no response"
  end

  if response.status == 429 then
    local retry_after = tonumber(response.headers and response.headers["retry-after"]) or 5
    vim.notify(string.format("Rate limited. Retrying in %ds...", retry_after), vim.log.levels.WARN)
    vim.wait(retry_after * 1000)
    response = curl.request(params)
  end

  if response.status < 200 or response.status >= 300 then
    return nil, string.format("HTTP %d: %s", response.status, response.body or "")
  end

  return process_response(response)
end

function M.async_request(method, base_url, path, opts)
  opts = opts or {}

  -- Fall back to token auth if no headers provided (legacy support)
  if not opts.headers then
    local auth = require("codereview.api.auth")
    local token, token_type = auth.get_token()
    if not token then
      return nil, "No authentication token. Run :CodeReviewAuth"
    end
    opts = vim.tbl_extend("keep", opts, { headers = build_headers(token, token_type) })
  end

  local params = build_params(method, base_url, path, opts)

  local response = async_util.wrap(curl.request, 2)(params)
  if not response then
    return nil, "Request failed: no response"
  end

  if response.status == 429 then
    local retry_after = tonumber(response.headers and response.headers["retry-after"]) or 5
    vim.schedule(function()
      vim.notify(string.format("Rate limited. Retrying in %ds...", retry_after), vim.log.levels.WARN)
    end)
    async_util.sleep(retry_after * 1000)
    response = async_util.wrap(curl.request, 2)(params)
  end

  if response.status < 200 or response.status >= 300 then
    return nil, string.format("HTTP %d: %s", response.status, response.body or "")
  end

  return process_response(response)
end

function M.get(base_url, path, opts) return M.request("get", base_url, path, opts) end
function M.post(base_url, path, opts) return M.request("post", base_url, path, opts) end
function M.put(base_url, path, opts) return M.request("put", base_url, path, opts) end
function M.delete(base_url, path, opts) return M.request("delete", base_url, path, opts) end

function M.async_get(base_url, path, opts) return M.async_request("get", base_url, path, opts) end
function M.async_post(base_url, path, opts) return M.async_request("post", base_url, path, opts) end
function M.async_put(base_url, path, opts) return M.async_request("put", base_url, path, opts) end
function M.async_delete(base_url, path, opts) return M.async_request("delete", base_url, path, opts) end
function M.patch(base_url, path, opts) return M.request("patch", base_url, path, opts) end
function M.async_patch(base_url, path, opts) return M.async_request("patch", base_url, path, opts) end

function M.get_url(full_url, opts)
  opts = opts or {}

  -- Fall back to token auth if no headers provided (legacy support)
  if not opts.headers then
    local auth = require("codereview.api.auth")
    local token, token_type = auth.get_token()
    if not token then
      return nil, "No authentication token. Run :CodeReviewAuth"
    end
    opts = vim.tbl_extend("keep", opts, { headers = build_headers(token, token_type) })
  end

  local params = {
    url = full_url,
    headers = opts.headers,
    method = "get",
  }

  local response = curl.request(params)
  if not response then
    return nil, "Request failed: no response"
  end

  if response.status < 200 or response.status >= 300 then
    return nil, string.format("HTTP %d: %s", response.status, response.body or "")
  end

  return process_response(response)
end

function M.paginate_all(base_url, path, opts)
  opts = vim.deepcopy(opts or {})
  local all_data = {}
  local page = 1
  local per_page = opts.per_page or 100

  while true do
    opts.query = opts.query or {}
    opts.query.page = page
    opts.query.per_page = per_page

    local result, err = M.get(base_url, path, opts)
    if not result then
      return nil, err
    end

    if type(result.data) == "table" then
      for _, item in ipairs(result.data) do
        table.insert(all_data, item)
      end
    end

    if not result.next_page then
      break
    end
    page = result.next_page
  end

  return all_data
end

function M.paginate_all_url(start_url, opts)
  local all_data = {}
  local current_url = start_url

  while current_url do
    local result, err = M.get_url(current_url, opts)
    if not result then
      return nil, err
    end

    if type(result.data) == "table" then
      for _, item in ipairs(result.data) do
        table.insert(all_data, item)
      end
    end

    current_url = result.next_url
  end

  return all_data
end

return M
