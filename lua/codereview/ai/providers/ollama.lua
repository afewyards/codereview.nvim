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

  local pcfg = cfg.ai.ollama or {}
  local base = (pcfg.base_url or "http://localhost:11434"):gsub("/$", "")
  local url = base .. "/api/chat"
  local body = {
    model = pcfg.model or "llama3",
    stream = false,
    messages = {
      { role = "user", content = prompt },
    },
  }

  log.debug("AI ollama: sending request, model=" .. body.model)
  return http.post_json(url, {}, body, function(response, err)
    if err then
      callback(nil, err)
      return
    end
    local text
    if response and response.message and response.message.content then
      text = response.message.content
    end
    if not text then
      callback(nil, "Unexpected response format from Ollama")
      return
    end
    log.debug("AI ollama: completed, output length=" .. #text)
    callback(text)
  end)
end

return M
