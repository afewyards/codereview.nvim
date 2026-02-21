local M = {}

function M.parse_remote(url)
  if not url or url == "" then
    return nil, nil
  end

  local host, path = url:match("^git@([^:]+):(.+)$")
  if host and path then
    path = path:gsub("%.git$", "")
    return host, path
  end

  host, path = url:match("^ssh://[^@]+@([^:/]+)[:%d]*/(.+)$")
  if host and path then
    path = path:gsub("%.git$", "")
    return host, path
  end

  host, path = url:match("^https?://([^/]+)/(.+)$")
  if host and path then
    path = path:gsub("%.git$", "")
    return host, path
  end

  return nil, nil
end

function M.get_remote_url()
  local result = vim.fn.systemlist({ "git", "remote", "get-url", "origin" })
  if vim.v.shell_error ~= 0 or #result == 0 then
    return nil
  end
  return vim.trim(result[1])
end

function M.detect_project()
  local config = require("glab_review.config").get()
  if config.gitlab_url and config.project then
    return config.gitlab_url, config.project
  end

  local url = M.get_remote_url()
  if not url then
    return nil, nil
  end

  local host, project = M.parse_remote(url)
  if not host then
    return nil, nil
  end

  return "https://" .. host, project
end

return M
