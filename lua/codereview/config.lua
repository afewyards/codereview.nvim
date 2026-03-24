-- lua/codereview/config.lua

---@class codereview.Config
---@field base_url? string API base URL override (auto-detected)
---@field project? string "owner/repo" override (auto-detected)
---@field platform? "github"|"gitlab" platform override (auto-detected)
---@field github_token? string GitHub personal access token
---@field gitlab_token? string GitLab personal access token
---@field picker? "telescope"|"fzf"|"snacks" picker override (auto-detected)
---@field debug? boolean debug logging to `.codereview.log` (default: `false`)
---@field open_in_tab? boolean open review in a new tab (set `false` to use current window) (default: `true`)
---@field diff? codereview.config.Diff diff viewer
---@field pipeline? codereview.config.Pipeline pipeline viewer
---@field ai? codereview.config.AI AI review
---@field keymaps? codereview.config.Keymap override or disable keybindings

---@class codereview.config.Diff
---@field context? integer lines of context (0-20) (default: 8)
---@field scroll_threshold? integer use scroll mode when file count <= threshold (default: 50)
---@field comment_width? integer comment float width (default: 80)
---@field separator_char? string hunk separator character
---@field separator_lines? integer lines in hunk separator (default: 3)

---@class codereview.config.Pipeline
---@field poll_interval? integer status poll interval (ms) (default: 10000)
---@field log_max_lines? integer max lines in job log viewer (default: 5000)

---@class codereview.config.AI
---@field enabled? boolean enable AI Review (default: `true`)
---@field provider? "claude_cli"|"codex_cli"|"copilot_cli"|"gemini_cli"|"qwen_cli"|"anthropic"|"openai"|"ollama"|"custom_cmd" AI Provider to use
---@field review_level? "info"|"suggestion"|"warning"|"error" controls the verbosity of AI code reviews (default: `info`)
---@field max_file_size? integer skip files larger than N lines (0 = unlimited) (default: 500)
---@field claude_cli? codereview.config.ai.ClaudeCli Claude CLI options
---@field codex_cli? codereview.config.ai.CodexCLI Codex CLI options
---@field copilot_cli? codereview.config.ai.CopilotCLI Copilot CLI options
---@field gemini_cli? codereview.config.ai.GeminiCLI Gemini CLI options
---@field qwen_cli? codereview.config.ai.QwenCLI Qwen CLI options
---@field anthropic? codereview.config.ai.Anthropic Anthropic API options
---@field openai? codereview.config.ai.OpenAI OpenAI API options
---@field ollama? codereview.config.ai.Ollama Ollama options
---@field custom_cmd? codereview.config.ai.CustomCmd Custom command options

---@class codereview.config.ai.ClaudeCli
---@field cmd? string Claude CLI command (default: `claude_cli`)
---@field agent? string Claude Agent (default: `code-review`)

---@class codereview.config.ai.CodexCLI
---@field cmd? string Codex CLI command (default: `codex`)
---@field model? string Codex model name

---@class codereview.config.ai.CopilotCLI
---@field cmd? string Copilot CLI command (default: `copilot`)
---@field model? string Copilot model name
---@field agent? string specify a custom agent to use

---@class codereview.config.ai.GeminiCLI
---@field cmd? string Gemini CLI command (default: `gemini`)
---@field model? string Gemini model name

---@class codereview.config.ai.QwenCLI
---@field cmd? string Qwen CLI command (default: `qwen`)
---@field model? string Qwen model name

---@class codereview.config.ai.Anthropic
---@field api_key? string Anthropic API key
---@field model? string Anthropic model name

---@class codereview.config.ai.OpenAI
---@field api_key? string OpenAI API key
---@field model? string OpenAI model name
---@field base_url? string OpenAI API base URL

---@class codereview.config.ai.Ollama
---@field model? string Ollama model name
---@field base_url? string Ollama API base URL

---@class codereview.config.ai.CustomCmd
---@field cmd? string shell command
---@field args? string[] command-line arguments

local M = {}

---@type codereview.Config
local defaults = {
  base_url = nil, -- API base URL override (auto-detected). Alias: gitlab_url
  project = nil,
  platform = nil, -- "github" | "gitlab" | nil (auto-detect)
  github_token = nil,
  gitlab_token = nil,
  picker = nil,
  debug = false, -- write request/auth logs to .codereview.log
  open_in_tab = true,
  diff = { context = 8, scroll_threshold = 50, comment_width = 80, separator_char = "╳", separator_lines = 3 },
  pipeline = { poll_interval = 10000, log_max_lines = 5000 },
  ai = {
    enabled = true,
    provider = "claude_cli",
    review_level = "info",
    max_file_size = 500,
    claude_cli = { cmd = "claude", agent = "code-review" },
    codex_cli = { cmd = "codex", model = nil },
    copilot_cli = { cmd = "copilot", model = nil, agent = nil },
    gemini_cli = { cmd = "gemini", model = nil },
    qwen_cli = { cmd = "qwen", model = nil },
    anthropic = { api_key = nil, model = "claude-sonnet-4-20250514" },
    openai = { api_key = nil, model = "gpt-4o", base_url = nil },
    ollama = { model = "llama3", base_url = "http://localhost:11434" },
    custom_cmd = { cmd = nil, args = {} },
  },
  keymaps = {},
}

---@type codereview.Config?
local current = nil

---@param base table
---@param override table
---@return table
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

---@param c codereview.Config
---@return codereview.Config
local function validate(c)
  c.diff.context = math.max(0, math.min(20, c.diff.context))
  local valid_levels = { info = true, suggestion = true, warning = true, error = true }
  if not valid_levels[c.ai.review_level] then
    c.ai.review_level = "info"
  end
  c.ai.max_file_size = math.max(0, c.ai.max_file_size or 500)
  local valid_providers = {
    claude_cli = true,
    codex_cli = true,
    copilot_cli = true,
    gemini_cli = true,
    qwen_cli = true,
    anthropic = true,
    openai = true,
    ollama = true,
    custom_cmd = true,
  }
  if not valid_providers[c.ai.provider] then
    c.ai.provider = "claude_cli"
  end
  return c
end

---@param opts? codereview.Config
function M.setup(opts)
  opts = opts or {}
  current = validate(deep_merge(defaults, opts))
  -- Backward compat: top-level claude_cmd/agent → claude_cli sub-table
  -- Only applies when user passed old keys without the new claude_cli sub-table
  local user_ai = opts.ai or {}
  local user_claude_cli = user_ai.claude_cli or {}
  ---@diagnostic disable-next-line: undefined-field
  if user_ai.claude_cmd and not user_claude_cli.cmd then
    ---@diagnostic disable-next-line: undefined-field
    current.ai.claude_cli.cmd = user_ai.claude_cmd
  end
  ---@diagnostic disable-next-line: undefined-field
  if user_ai.agent and not user_claude_cli.agent then
    ---@diagnostic disable-next-line: undefined-field
    current.ai.claude_cli.agent = user_ai.agent
  end
  -- Backward compat: gitlab_url → base_url
  ---@diagnostic disable-next-line: undefined-field
  if current.gitlab_url and not current.base_url then
    ---@diagnostic disable-next-line: undefined-field
    current.base_url = current.gitlab_url
  end
  ---@diagnostic disable-next-line: undefined-field
  if current.token then
    vim.notify(
      "[codereview] `token` is deprecated and will NOT be used. Set `github_token` or `gitlab_token` instead.",
      vim.log.levels.WARN
    )
  end
  require("codereview.keymaps").setup(current.keymaps)
end

---@return codereview.Config
function M.get()
  return current or vim.deepcopy(defaults)
end

function M.reset()
  current = nil
end

return M
