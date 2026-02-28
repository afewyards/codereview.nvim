_G.vim = _G.vim or {}
vim.fn = vim.fn or {}
vim.fn.jobstart = vim.fn.jobstart or function() return 1 end
vim.fn.chansend = vim.fn.chansend or function() end
vim.fn.chanclose = vim.fn.chanclose or function() end
vim.schedule = vim.schedule or function(fn) fn() end

package.loaded["codereview.config"] = {
  get = function()
    return { ai = { enabled = true, provider = "custom_cmd", custom_cmd = { cmd = "my-ai", args = { "--json" } } } }
  end,
}
package.loaded["codereview.log"] = { debug = function() end, warn = function() end, error = function() end }

local custom_cmd = require("codereview.ai.providers.custom_cmd")

describe("ai.providers.custom_cmd", function()
  it("builds command with args", function()
    local cmd = custom_cmd.build_cmd("my-ai", { "--json", "--model", "x" })
    assert.same({ "my-ai", "--json", "--model", "x" }, cmd)
  end)

  it("returns error when cmd not configured", function()
    package.loaded["codereview.config"].get = function()
      return { ai = { enabled = true, provider = "custom_cmd", custom_cmd = { args = {} } } }
    end
    local result, err
    custom_cmd.run("test", function(o, e) result = o; err = e end)
    assert.is_nil(result)
    assert.truthy(err:find("cmd"))
  end)
end)
