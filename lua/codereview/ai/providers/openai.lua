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

  local pcfg = cfg.ai.openai or {}
  if not pcfg.api_key or pcfg.api_key == "" then
    callback(nil, "OpenAI api_key not configured (set ai.openai.api_key)")
    return
  end

  local base = pcfg.base_url or "https://api.openai.com"
  base = base:gsub("/$", "")
  local url = base .. "/v1/chat/completions"
  local headers = {
    ["Authorization"] = "Bearer " .. pcfg.api_key,
  }
  local body = {
    model = pcfg.model or "gpt-4o",
    messages = {
      { role = "user", content = prompt },
    },
  }

  log.debug("AI openai: sending request, model=" .. body.model)
  return http.post_json(url, headers, body, function(response, err)
    if err then
      callback(nil, err)
      return
    end
    local text
    if response and response.choices and response.choices[1] and response.choices[1].message then
      text = response.choices[1].message.content
    end
    if not text then
      callback(nil, "Unexpected response format from OpenAI API")
      return
    end
    log.debug("AI openai: completed, output length=" .. #text)
    callback(text)
  end)
end

return M
