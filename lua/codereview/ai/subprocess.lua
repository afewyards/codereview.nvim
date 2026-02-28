-- lua/codereview/ai/subprocess.lua
-- DEPRECATED: Use require("codereview.ai.providers").get() instead.
-- Kept for backward compatibility with external consumers.
return require("codereview.ai.providers.claude_cli")
