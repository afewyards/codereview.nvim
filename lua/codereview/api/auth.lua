local log = require("codereview.log")
local M = {}

local cached = {} -- { [platform] = { token, type } }
local _config_file_read = false
local _config_file_cache = nil

local function read_config_file()
  if _config_file_read then
    return _config_file_cache
  end
  _config_file_read = true

  local git = require("codereview.git")
  local root = git.get_repo_root()
  local config_path = root and (root .. "/.codereview.json") or nil

  if not config_path or vim.fn.filereadable(config_path) == 0 then
    return nil
  end

  local lines = vim.fn.readfile(config_path)
  if not lines or #lines == 0 then
    return nil
  end

  local content = table.concat(lines, "\n")
  local ok, parsed = pcall(vim.json.decode, content)
  if not ok or type(parsed) ~= "table" then
    return nil
  end

  -- Gitignore safety check if file contains tokens
  local has_token = parsed.token or parsed.github_token or parsed.gitlab_token
  if has_token then
    local handle = io.popen("git check-ignore -q " .. vim.fn.shellescape(config_path) .. " 2>/dev/null; echo $?")
    if handle then
      local exit_code = handle:read("*a"):match("(%d+)%s*$")
      handle:close()
      if exit_code ~= "0" then
        vim.notify(".codereview.json contains tokens but is NOT in .gitignore!", vim.log.levels.WARN)
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

  -- 2. .codereview.json platform-scoped token
  local file_config = read_config_file()
  if file_config then
    local scoped_key = platform .. "_token"
    local scoped_token = file_config[scoped_key]
    if scoped_token and scoped_token ~= "" then
      log.info("get_token: using .codereview.json " .. scoped_key)
      cached[platform] = { token = scoped_token, type = "pat" }
      return scoped_token, "pat"
    end
    -- 3. .codereview.json generic token
    if file_config.token and file_config.token ~= "" then
      log.info("get_token: using .codereview.json generic token")
      cached[platform] = { token = file_config.token, type = "pat" }
      return file_config.token, "pat"
    end
  end

  -- 4. Plugin config
  local config = require("codereview.config").get()
  if config.token then
    log.info("get_token: using plugin config token")
    cached[platform] = { token = config.token, type = "pat" }
    return config.token, "pat"
  end

  log.warn("get_token: no token found for platform=" .. platform)
  return nil, nil
end

function M.refresh(platform)
  platform = platform or "gitlab"
  cached[platform] = nil
  return nil, nil
end

return M
