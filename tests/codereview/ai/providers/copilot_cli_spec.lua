package.loaded["codereview.config"] = {
  get = function()
    return {
      ai = { enabled = true, provider = "copilot_cli", copilot_cli = { cmd = "copilot", model = nil, agent = nil } },
    }
  end,
}
package.loaded["codereview.log"] = { debug = function() end, warn = function() end, error = function() end }

local copilot_cli = require("codereview.ai.providers.copilot_cli")

describe("ai.providers.copilot_cli", function()
  describe("build_cmd", function()
    it("builds default copilot command", function()
      assert.same({ "copilot", "--silent", "--no-auto-update" }, copilot_cli.build_cmd("copilot"))
    end)
    it("includes model flag when provided", function()
      assert.same(
        { "copilot", "--silent", "--no-auto-update", "--model", "model" },
        copilot_cli.build_cmd("copilot", "model")
      )
    end)
    it("includes agent flag when provided", function()
      assert.same(
        { "copilot", "--silent", "--no-auto-update", "--agent", "agent" },
        copilot_cli.build_cmd("copilot", nil, "agent")
      )
    end)
  end)
end)
