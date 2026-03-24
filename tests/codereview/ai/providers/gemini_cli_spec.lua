package.loaded["codereview.config"] = {
  get = function()
    return {
      ai = { enabled = true, provider = "gemini_cli", gemini_cli = { cmd = "gemini", model = nil } },
    }
  end,
}
package.loaded["codereview.log"] = { debug = function() end, warn = function() end, error = function() end }

local gemini_cli = require("codereview.ai.providers.gemini_cli")

describe("ai.providers.gemini_cli", function()
  describe("build_cmd", function()
    it("builds default gemini command", function()
      assert.same({ "gemini", "--approval-mode=plan" }, gemini_cli.build_cmd("gemini"))
    end)
    it("includes model flag when provided", function()
      assert.same({ "gemini", "--approval-mode=plan", "--model", "model" }, gemini_cli.build_cmd("gemini", "model"))
    end)
  end)
end)
