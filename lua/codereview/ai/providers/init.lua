local M = {}

local valid_providers = {
  claude_cli = "codereview.ai.providers.claude_cli",
  anthropic  = "codereview.ai.providers.anthropic",
  openai     = "codereview.ai.providers.openai",
  ollama     = "codereview.ai.providers.ollama",
  custom_cmd = "codereview.ai.providers.custom_cmd",
}

function M.get()
  local cfg = require("codereview.config").get()
  local name = cfg.ai.provider or "claude_cli"
  local mod_path = valid_providers[name]
  if not mod_path then
    error(string.format("[codereview] Unknown AI provider: %q", name))
  end
  return require(mod_path)
end

return M
