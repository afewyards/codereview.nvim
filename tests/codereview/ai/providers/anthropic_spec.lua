_G.vim = _G.vim or {}
vim.fn = vim.fn or {}
vim.fn.jobstart = vim.fn.jobstart or function() return 1 end
vim.fn.chansend = vim.fn.chansend or function() end
vim.fn.chanclose = vim.fn.chanclose or function() end
vim.schedule = vim.schedule or function(fn) fn() end
vim.json = vim.json or {}
vim.json.encode = vim.json.encode or require("cjson").encode
vim.json.decode = vim.json.decode or require("cjson").decode

package.loaded["codereview.config"] = {
  get = function()
    return { ai = { enabled = true, provider = "anthropic", anthropic = { api_key = "sk-test", model = "claude-sonnet-4-20250514" } } }
  end,
}
package.loaded["codereview.log"] = { debug = function() end, warn = function() end, error = function() end }

-- Stub http to capture calls
local http_calls = {}
package.loaded["codereview.ai.providers.http"] = {
  post_json = function(url, headers, body, callback)
    table.insert(http_calls, { url = url, headers = headers, body = body })
    callback({ content = { { type = "text", text = "AI response" } } })
    return 1
  end,
}

local anthropic = require("codereview.ai.providers.anthropic")

describe("ai.providers.anthropic", function()
  before_each(function() http_calls = {} end)

  it("sends prompt to messages API", function()
    local result, err
    anthropic.run("Review this code", function(o, e) result = o; err = e end)
    assert.is_nil(err)
    assert.equals("AI response", result)
    assert.equals(1, #http_calls)
    assert.truthy(http_calls[1].url:find("anthropic.com"))
    assert.equals("sk-test", http_calls[1].headers["x-api-key"])
  end)

  it("returns error when disabled", function()
    package.loaded["codereview.config"].get = function()
      return { ai = { enabled = false, provider = "anthropic", anthropic = { api_key = "sk-test", model = "claude-sonnet-4-20250514" } } }
    end
    local result, err
    anthropic.run("test", function(o, e) result = o; err = e end)
    assert.is_nil(result)
    assert.truthy(err:find("disabled"))
  end)

  it("returns error when api_key missing", function()
    package.loaded["codereview.config"].get = function()
      return { ai = { enabled = true, provider = "anthropic", anthropic = { model = "claude-sonnet-4-20250514" } } }
    end
    local result, err
    anthropic.run("test", function(o, e) result = o; err = e end)
    assert.is_nil(result)
    assert.truthy(err:find("api_key"))
  end)
end)
