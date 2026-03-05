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

--- Run a shell command and return trimmed stdout, or nil on failure.
--- Uses io.popen so it is safe to call from plenary.async coroutines
--- (vim.fn.systemlist is not).
local function shell(cmd)
  local handle = io.popen(cmd)
  if not handle then
    return nil
  end
  local out = handle:read("*a")
  handle:close()
  if not out or out == "" then
    return nil
  end
  return vim.trim(out)
end

function M.get_repo_root()
  return shell("git rev-parse --show-toplevel 2>/dev/null")
end

function M.get_remote_url()
  return shell("git remote get-url origin 2>/dev/null")
end

function M.detect_project()
  local config = require("codereview.config").get()
  if config.base_url and config.project then
    return config.base_url, config.project
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
