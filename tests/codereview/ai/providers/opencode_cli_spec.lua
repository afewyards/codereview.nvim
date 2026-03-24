package.loaded["codereview.config"] = {
  get = function()
    return {
      ai = {
        enabled = true,
        provider = "opencode_cli",
        opencode_cli = { cmd = "opencode", model = nil, agent = "plan", variant = nil },
      },
    }
  end,
}
package.loaded["codereview.log"] = { debug = function() end, warn = function() end, error = function() end }

local opencode_cli = require("codereview.ai.providers.opencode_cli")

describe("ai.providers.opencode_cli", function()
  describe("build_cmd", function()
    it("builds default opencode command", function()
      assert.same({ "opencode", "run", "--" }, opencode_cli.build_cmd("opencode"))
    end)
    it("includes model flag when provided", function()
      assert.same({ "opencode", "run", "--model", "model", "--" }, opencode_cli.build_cmd("opencode", "model"))
    end)
    it("includes agent flag when provided", function()
      assert.same({ "opencode", "run", "--agent", "agent", "--" }, opencode_cli.build_cmd("opencode", nil, "agent"))
    end)
    it("includes variant flag when provided", function()
      assert.same(
        { "opencode", "run", "--variant", "variant", "--" },
        opencode_cli.build_cmd("opencode", nil, nil, "variant")
      )
    end)
  end)
end)
