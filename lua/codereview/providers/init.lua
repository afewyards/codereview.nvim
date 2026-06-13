local M = {}

local GITHUB_HOSTS = { ["github.com"] = true }

function M.detect_platform(host)
  if not host then
    return "gitlab"
  end
  if GITHUB_HOSTS[host] then
    return "github"
  end
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

  local file_cfg = require("codereview.api.auth").get_file_config() or {}
  local eff_base_url = file_cfg.base_url or config.base_url
  local eff_project = file_cfg.project or config.project
  local eff_platform = file_cfg.platform or config.platform

  local host, project
  if eff_base_url and eff_project then
    local url = eff_base_url
    host = url:match("^https?://([^/]+)")
    project = eff_project
  else
    local remote_url = git.get_remote_url()
    if not remote_url then
      return nil, nil, "Could not get git remote"
    end
    host, project = git.parse_remote(remote_url)
    if not host then
      return nil, nil, "Could not parse git remote"
    end
  end

  local platform = eff_platform or M.detect_platform(host)
  local provider = M.get_provider(platform)

  local base_url
  if platform == "github" then
    base_url = eff_base_url or "https://api.github.com"
  else
    base_url = eff_base_url or ("https://" .. host)
  end

  return provider, { base_url = base_url, project = project, host = host, platform = platform }, nil
end

return M
