local config = require("codereview.config")
local log = require("codereview.log")
local http = require("codereview.ai.providers.http")
local M = {}

function M.run(prompt, callback, opts)
  local cfg = config.get()
  if not cfg.ai.enabled then
    callback(nil, "AI review is disabled in config")
    return
  end

  local pcfg = cfg.ai.anthropic or {}
  if not pcfg.api_key or pcfg.api_key == "" then
    callback(nil, "Anthropic api_key not configured (set ai.anthropic.api_key)")
    return
  end

  local url = "https://api.anthropic.com/v1/messages"
  local headers = {
    ["x-api-key"] = pcfg.api_key,
    ["anthropic-version"] = "2023-06-01",
  }
  local body = {
    model = pcfg.model or "claude-sonnet-4-20250514",
    max_tokens = 8192,
    messages = {
      { role = "user", content = prompt },
    },
  }

  log.debug("AI anthropic: sending request, model=" .. body.model)
  return http.post_json(url, headers, body, function(response, err)
    if err then
      callback(nil, err)
      return
    end
    -- Extract text from response.content[1].text
    local text
    if response and response.content and response.content[1] then
      text = response.content[1].text
    end
    if not text then
      callback(nil, "Unexpected response format from Anthropic API")
      return
    end
    log.debug("AI anthropic: completed, output length=" .. #text)
    callback(text)
  end)
end

return M
