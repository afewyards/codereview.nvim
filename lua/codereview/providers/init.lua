local M = {}

local GITHUB_HOSTS = { ["github.com"] = true }

function M.detect_platform(host)
  if not host then return "gitlab" end
  if GITHUB_HOSTS[host] then return "github" end
  return "gitlab"
end

function M.get_provider(platform)
  if platform == "gitlab" then
    return require("codereview.providers.gitlab")
  elseif platform == "github" then
    return require("codereview.providers.github")
  else
    error("Unknown platform: " .. tostring(platform))
  end
end

function M.detect()
  local config = require("codereview.config").get()
  local git = require("codereview.git")

  local host, project
  if config.base_url and config.project then
    local url = config.base_url
    host = url:match("^https?://([^/]+)")
    project = config.project
  else
    local remote_url = git.get_remote_url()
    if not remote_url then return nil, nil, "Could not get git remote" end
    host, project = git.parse_remote(remote_url)
    if not host then return nil, nil, "Could not parse git remote" end
  end

  local platform = config.platform or M.detect_platform(host)
  local provider = M.get_provider(platform)

  local base_url
  if platform == "github" then
    base_url = config.base_url or "https://api.github.com"
  else
    base_url = config.base_url or ("https://" .. host)
  end

  return provider, { base_url = base_url, project = project, host = host, platform = platform }, nil
end

return M
