package.loaded["codereview.config"] = {
  get = function()
    return {
      ai = { enabled = true, provider = "qwen_cli", qwen_cli = { cmd = "qwen", model = nil } },
    }
  end,
}
package.loaded["codereview.log"] = { debug = function() end, warn = function() end, error = function() end }

local qwen_cli = require("codereview.ai.providers.qwen_cli")

describe("ai.providers.qwen_cli", function()
  describe("build_cmd", function()
    it("builds default qwen command", function()
      assert.same({ "qwen", "--approval-mode=plan" }, qwen_cli.build_cmd("qwen"))
    end)
    it("includes model flag when provided", function()
      assert.same({ "qwen", "--approval-mode=plan", "--model", "model" }, qwen_cli.build_cmd("qwen", "model"))
    end)
  end)
end)
