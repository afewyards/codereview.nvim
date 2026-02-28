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
  diff = { context = 8, scroll_threshold = 50, comment_width = 80, separator_char = "╳", separator_lines = 3 },
  ai = {
    enabled = true,
    provider = "claude_cli",
    review_level = "info",
    max_file_size = 500,
    claude_cli = { cmd = "claude", agent = "code-review" },
    anthropic  = { api_key = nil, model = "claude-sonnet-4-20250514" },
    openai     = { api_key = nil, model = "gpt-4o", base_url = nil },
    ollama     = { model = "llama3", base_url = "http://localhost:11434" },
    custom_cmd = { cmd = nil, args = {} },
  },
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
  c.ai.max_file_size = math.max(0, c.ai.max_file_size or 500)
  local valid_providers = { claude_cli = true, anthropic = true, openai = true, ollama = true, custom_cmd = true }
  if not valid_providers[c.ai.provider] then
    c.ai.provider = "claude_cli"
  end
  return c
end

function M.setup(opts)
  opts = opts or {}
  current = validate(deep_merge(defaults, opts))
  -- Backward compat: top-level claude_cmd/agent → claude_cli sub-table
  -- Only applies when user passed old keys without the new claude_cli sub-table
  local user_ai = opts.ai or {}
  local user_claude_cli = user_ai.claude_cli or {}
  if user_ai.claude_cmd and not user_claude_cli.cmd then
    current.ai.claude_cli.cmd = user_ai.claude_cmd
  end
  if user_ai.agent and not user_claude_cli.agent then
    current.ai.claude_cli.agent = user_ai.agent
  end
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
