-- lua/codereview/config.lua
local M = {}

local defaults = {
  base_url = nil,     -- API base URL override (auto-detected). Alias: gitlab_url
  project = nil,
  platform = nil,     -- "github" | "gitlab" | nil (auto-detect)
  github_token = nil,
  gitlab_token = nil,
  picker = nil,
  debug = false,      -- write request/auth logs to .codereview.log
  diff = { context = 8, scroll_threshold = 50, comment_width = 80 },
  ai = { enabled = true, claude_cmd = "claude", agent = "code-review", review_level = "info" },
  keymaps = {},
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
  local valid_levels = { info = true, suggestion = true, warning = true, error = true }
  if not valid_levels[c.ai.review_level] then
    c.ai.review_level = "info"
  end
  return c
end

function M.setup(opts)
  current = validate(deep_merge(defaults, opts or {}))
  -- Backward compat: gitlab_url → base_url
  if current.gitlab_url and not current.base_url then
    current.base_url = current.gitlab_url
  end
  if current.token then
    vim.notify(
      "[codereview] `token` is deprecated and will NOT be used. Set `github_token` or `gitlab_token` instead.",
      vim.log.levels.WARN
    )
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
