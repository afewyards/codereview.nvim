package.loaded["codereview.config"] = {
  get = function()
    return { ai = { provider = "claude_cli", claude_cli = { cmd = "claude", agent = "code-review" } } }
  end,
}
package.loaded["codereview.log"] = { debug = function() end, warn = function() end, error = function() end }

local providers = require("codereview.ai.providers")

describe("ai.providers", function()
  it("returns claude_cli provider by default", function()
    local p = providers.get()
    assert.is_function(p.run)
  end)

  it("errors on unknown provider", function()
    package.loaded["codereview.config"].get = function()
      return { ai = { provider = "nonexistent" } }
    end
    assert.has_error(function() providers.get() end)
  end)
end)
