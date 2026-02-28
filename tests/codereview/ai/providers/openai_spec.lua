_G.vim = _G.vim or {}
vim.fn = vim.fn or {}
vim.fn.jobstart = vim.fn.jobstart or function() return 1 end
vim.schedule = vim.schedule or function(fn) fn() end
vim.json = vim.json or {}
vim.json.encode = vim.json.encode or require("cjson").encode
vim.json.decode = vim.json.decode or require("cjson").decode

package.loaded["codereview.config"] = {
  get = function()
    return { ai = { enabled = true, provider = "openai", openai = { api_key = "sk-test", model = "gpt-4o" } } }
  end,
}
package.loaded["codereview.log"] = { debug = function() end, warn = function() end, error = function() end }

local http_calls = {}
package.loaded["codereview.ai.providers.http"] = {
  post_json = function(url, headers, body, callback)
    table.insert(http_calls, { url = url, headers = headers, body = body })
    callback({ choices = { { message = { content = "AI response" } } } })
    return 1
  end,
}

local openai = require("codereview.ai.providers.openai")

describe("ai.providers.openai", function()
  before_each(function() http_calls = {} end)

  it("sends prompt to chat completions API", function()
    local result, err
    openai.run("Review this code", function(o, e) result = o; err = e end)
    assert.is_nil(err)
    assert.equals("AI response", result)
    assert.equals(1, #http_calls)
    assert.truthy(http_calls[1].url:find("openai.com"))
  end)

  it("uses custom base_url when configured", function()
    package.loaded["codereview.config"].get = function()
      return { ai = { enabled = true, provider = "openai", openai = { api_key = "sk-test", model = "gpt-4o", base_url = "https://custom.api.com" } } }
    end
    openai.run("test", function() end)
    assert.truthy(http_calls[1].url:find("custom.api.com"))
  end)

  it("returns error when api_key missing", function()
    package.loaded["codereview.config"].get = function()
      return { ai = { enabled = true, provider = "openai", openai = { model = "gpt-4o" } } }
    end
    local result, err
    openai.run("test", function(o, e) result = o; err = e end)
    assert.is_nil(result)
    assert.truthy(err:find("api_key"))
  end)
end)
