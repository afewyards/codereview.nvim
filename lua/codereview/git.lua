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

function M.get_current_branch()
  return shell("git rev-parse --abbrev-ref HEAD 2>/dev/null")
end

function M.branch_exists(name)
  local result = shell("git rev-parse --verify " .. name .. " 2>/dev/null")
  return result ~= nil
end

function M.get_default_base()
  if M.branch_exists("main") then
    return "main"
  elseif M.branch_exists("master") then
    return "master"
  end
  return nil
end

function M.sanitize_branch_name(name)
  if not name then
    return nil
  end
  return name:gsub("/", "-")
end

function M.diff_against_base(base)
  local diff_output = shell("git diff " .. base .. "..HEAD --no-color 2>/dev/null")
  if not diff_output or diff_output == "" then
    return {}
  end

  local files = {}
  local current_file = nil
  local current_diff = {}

  for line in (diff_output .. "\n"):gmatch("(.-)\n") do
    local new_path = line:match("^%+%+%+ b/(.+)$")
    local old_path = line:match("^%-%-%- a/(.+)$")

    if line:match("^diff %-%-git") then
      if current_file then
        table.insert(files, {
          new_path = current_file.new_path,
          old_path = current_file.old_path,
          diff = table.concat(current_diff, "\n"),
        })
      end
      current_file = {}
      current_diff = { line }
    elseif old_path and current_file then
      current_file.old_path = old_path
      table.insert(current_diff, line)
    elseif new_path and current_file then
      current_file.new_path = new_path
      table.insert(current_diff, line)
    elseif current_file then
      table.insert(current_diff, line)
    end
  end

  if current_file then
    table.insert(files, {
      new_path = current_file.new_path,
      old_path = current_file.old_path,
      diff = table.concat(current_diff, "\n"),
    })
  end

  return files
end

return M
