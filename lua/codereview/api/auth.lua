local log = require("codereview.log")
local M = {}

local cached = {} -- { [platform] = { token, type } }
local _config_file_read = false
local _config_file_cache = nil

local function parse_dotenv(lines)
  local result = {}
  for _, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local key, value = trimmed:match("^([^=]+)=(.*)")
      if key and value then
        key = key:match("^%s*(.-)%s*$")
        value = value:match("^%s*(.-)%s*$")
        result[key] = value
      end
    end
  end
  return result
end

local function read_config_file()
  if _config_file_read then
    return _config_file_cache
  end
  _config_file_read = true

  local git = require("codereview.git")
  local root = git.get_repo_root()
  local config_path = root and (root .. "/.codereview.nvim") or nil

  if not config_path or vim.fn.filereadable(config_path) == 0 then
    return nil
  end

  local lines = vim.fn.readfile(config_path)
  if not lines or #lines == 0 then
    return nil
  end

  local parsed = parse_dotenv(lines)

  -- Gitignore safety check if file contains tokens
  local has_token = parsed.token
  if has_token then
    local handle = io.popen("git check-ignore -q " .. vim.fn.shellescape(config_path) .. " 2>/dev/null; echo $?")
    if handle then
      local exit_code = handle:read("*a"):match("(%d+)%s*$")
      handle:close()
      if exit_code ~= "0" then
        vim.notify(".codereview.nvim contains tokens but is NOT in .gitignore!", vim.log.levels.WARN)
      end
    end
  end

  _config_file_cache = parsed
  return parsed
end

function M.reset()
  cached = {}
  _config_file_read = false
  _config_file_cache = nil
end

--- Returns token, token_type. token_type is always "pat" for now.
--- @param platform string|nil "github" | "gitlab" (defaults to "gitlab")
function M.get_token(platform)
  platform = platform or "gitlab"
  if cached[platform] then
    return cached[platform].token, cached[platform].type
  end

  log.debug("get_token: resolving for platform=" .. platform)

  -- 1. Environment variable
  local env_var = platform == "github" and "GITHUB_TOKEN" or "GITLAB_TOKEN"
  local env_token = os.getenv(env_var)
  if env_token and env_token ~= "" then
    log.info("get_token: using " .. env_var .. " env var")
    cached[platform] = { token = env_token, type = "pat" }
    return env_token, "pat"
  end

  -- 2. .codereview.nvim generic token
  local file_config = read_config_file()
  if file_config and file_config.token and file_config.token ~= "" then
    log.info("get_token: using .codereview.nvim token")
    cached[platform] = { token = file_config.token, type = "pat" }
    return file_config.token, "pat"
  end

  -- 3. Plugin config (platform-specific)
  local config = require("codereview.config").get()
  local config_key = platform == "github" and "github_token" or "gitlab_token"
  if config[config_key] then
    log.info("get_token: using plugin config " .. config_key)
    cached[platform] = { token = config[config_key], type = "pat" }
    return config[config_key], "pat"
  end

  log.warn("get_token: no token found for platform=" .. platform)
  return nil, nil
end

function M.refresh(platform)
  platform = platform or "gitlab"
  cached[platform] = nil
  return nil, nil
end

-- Exposed for testing only
M._read_config_file_for_test = function()
  return read_config_file()
end

return M
