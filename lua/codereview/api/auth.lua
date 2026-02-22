local M = {}

local cached_token = nil
local cached_token_type = nil

function M.reset()
  cached_token = nil
  cached_token_type = nil
end

--- Returns token, token_type. token_type is always "pat" for now.
function M.get_token()
  if cached_token then
    return cached_token, cached_token_type
  end

  -- 1. GITLAB_TOKEN env var
  local env_token = os.getenv("GITLAB_TOKEN")
  if env_token and env_token ~= "" then
    cached_token = env_token
    cached_token_type = "pat"
    return cached_token, cached_token_type
  end

  -- 2. Config token
  local config = require("codereview.config").get()
  if config.token then
    cached_token = config.token
    cached_token_type = "pat"
    return cached_token, cached_token_type
  end

  return nil, nil
end

function M.refresh()
  cached_token = nil
  cached_token_type = nil
  return nil, nil
end

return M
