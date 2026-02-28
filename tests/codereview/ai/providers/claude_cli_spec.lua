package.loaded["codereview.config"] = {
  get = function()
    return { ai = { enabled = true, provider = "claude_cli", claude_cli = { cmd = "claude", agent = "code-review" } } }
  end,
}
package.loaded["codereview.log"] = { debug = function() end, warn = function() end, error = function() end }

local claude_cli = require("codereview.ai.providers.claude_cli")

describe("ai.providers.claude_cli", function()
  describe("build_cmd", function()
    it("builds default claude command", function()
      assert.same({ "claude", "-p" }, claude_cli.build_cmd("claude"))
    end)
    it("includes agent flag when provided", function()
      assert.same({ "claude", "-p", "--agent", "code-review" }, claude_cli.build_cmd("claude", "code-review"))
    end)
    it("omits agent flag when nil", function()
      assert.same({ "claude", "-p" }, claude_cli.build_cmd("claude", nil))
    end)
  end)
end)
