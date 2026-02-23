-- lua/codereview/config.lua
local M = {}

local defaults = {
  base_url = nil,     -- API base URL override (auto-detected). Alias: gitlab_url
  project = nil,
  platform = nil,     -- "github" | "gitlab" | nil (auto-detect)
  token = nil,
  picker = nil,
  debug = false,      -- write request/auth logs to .codereview.log
  diff = { context = 8, scroll_threshold = 50 },
  ai = { enabled = true, claude_cmd = "claude", agent = "code-review" },
  keymaps = {},
  notifications = {
    enabled = true,
    timeout = 3000,        -- ms before notification auto-dismisses
    position = "top_right", -- "top_right" | "bottom_right" | "top_left"
  },
  cache = {
    enabled = true,
    ttl = 300,             -- seconds to cache API responses
  },
}

local current = nil

local function deep_merge(base, override)
  local result = vim.deepcopy(base)
  for k, v in pairs(override) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

local function validate(c)
  c.diff.context = math.max(0, math.min(20, c.diff.context))
  if c.notifications then
    c.notifications.timeout = math.max(500, c.notifications.timeout or 3000)
    local valid_positions = { top_right = true, bottom_right = true, top_left = true }
    if not valid_positions[c.notifications.position] then
      c.notifications.position = "top_right"
    end
  end
  if c.cache then
    c.cache.ttl = math.max(0, c.cache.ttl or 300)
  end
  return c
end

function M.setup(opts)
  current = validate(deep_merge(defaults, opts or {}))
  -- Backward compat: gitlab_url → base_url
  if current.gitlab_url and not current.base_url then
    current.base_url = current.gitlab_url
  end
  require("codereview.keymaps").setup(current.keymaps)
end

function M.get()
  return current or vim.deepcopy(defaults)
end

function M.reset()
  current = nil
end

return M
