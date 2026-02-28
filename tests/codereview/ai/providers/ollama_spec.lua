_G.vim = _G.vim or {}
vim.fn = vim.fn or {}
vim.fn.jobstart = vim.fn.jobstart or function() return 1 end
vim.schedule = vim.schedule or function(fn) fn() end
vim.json = vim.json or {}
vim.json.encode = vim.json.encode or require("cjson").encode
vim.json.decode = vim.json.decode or require("cjson").decode

package.loaded["codereview.config"] = {
  get = function()
    return { ai = { enabled = true, provider = "ollama", ollama = { model = "llama3", base_url = "http://localhost:11434" } } }
  end,
}
package.loaded["codereview.log"] = { debug = function() end, warn = function() end, error = function() end }

local http_calls = {}
package.loaded["codereview.ai.providers.http"] = {
  post_json = function(url, headers, body, callback)
    table.insert(http_calls, { url = url, headers = headers, body = body })
    callback({ message = { content = "AI response" } })
    return 1
  end,
}

local ollama = require("codereview.ai.providers.ollama")

describe("ai.providers.ollama", function()
  before_each(function() http_calls = {} end)

  it("sends prompt to ollama chat API", function()
    local result, err
    ollama.run("Review this code", function(o, e) result = o; err = e end)
    assert.is_nil(err)
    assert.equals("AI response", result)
    assert.equals(1, #http_calls)
    assert.truthy(http_calls[1].url:find("localhost:11434"))
  end)

  it("does not require api_key", function()
    local result, err
    ollama.run("test", function(o, e) result = o; err = e end)
    assert.is_nil(err)
    assert.truthy(result)
  end)

  it("uses custom base_url", function()
    package.loaded["codereview.config"].get = function()
      return { ai = { enabled = true, provider = "ollama", ollama = { model = "llama3", base_url = "http://remote:11434" } } }
    end
    ollama.run("test", function() end)
    assert.truthy(http_calls[1].url:find("remote:11434"))
  end)
end)
