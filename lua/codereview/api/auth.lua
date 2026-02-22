local M = {}

local cached = {} -- { [platform] = { token, type } }

function M.reset() cached = {} end

--- Returns token, token_type. token_type is always "pat" for now.
--- @param platform string|nil "github" | "gitlab" (defaults to "gitlab")
function M.get_token(platform)
  platform = platform or "gitlab"
  if cached[platform] then
    return cached[platform].token, cached[platform].type
  end

  local env_var = platform == "github" and "GITHUB_TOKEN" or "GITLAB_TOKEN"
  local env_token = os.getenv(env_var)
  if env_token and env_token ~= "" then
    cached[platform] = { token = env_token, type = "pat" }
    return env_token, "pat"
  end

  local config = require("codereview.config").get()
  if config.token then
    cached[platform] = { token = config.token, type = "pat" }
    return config.token, "pat"
  end

  return nil, nil
end

function M.refresh(platform)
  platform = platform or "gitlab"
  cached[platform] = nil
  return nil, nil
end

return M
