_G.vim = _G.vim or {}
vim.fn = vim.fn or {}
vim.schedule = vim.schedule or function(fn) fn() end
vim.json = vim.json or { encode = function(t) return '{}' end }
vim.tbl_contains = vim.tbl_contains or function(tbl, val)
  for _, v in ipairs(tbl) do
    if v == val then return true end
  end
  return false
end

package.loaded["codereview.log"] = { debug = function() end, warn = function() end, error = function() end }

local http = require("codereview.ai.providers.http")

describe("ai.providers.http", function()
  describe("build_curl_cmd", function()
    it("builds POST request with headers and body", function()
      local cmd = http.build_curl_cmd("https://api.example.com/v1/chat", {
        ["Authorization"] = "Bearer sk-test",
        ["Content-Type"] = "application/json",
      }, '{"model":"gpt-4o"}')
      assert.truthy(vim.tbl_contains(cmd, "curl"))
      assert.truthy(vim.tbl_contains(cmd, "-sS"))
      assert.truthy(vim.tbl_contains(cmd, "https://api.example.com/v1/chat"))
    end)
  end)
end)
