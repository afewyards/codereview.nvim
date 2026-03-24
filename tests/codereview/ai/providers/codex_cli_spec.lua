package.loaded["codereview.config"] = {
  get = function()
    return { ai = { enabled = true, provider = "codex_cli", codex_cli = { cmd = "codex", model = nil } } }
  end,
}
package.loaded["codereview.log"] = { debug = function() end, warn = function() end, error = function() end }

local codex_cli = require("codereview.ai.providers.codex_cli")

describe("ai.providers.codex_cli", function()
  describe("build_cmd", function()
    it("builds default codex command", function()
      assert.same({ "codex", "exec", "--sandbox=read-only", "--" }, codex_cli.build_cmd("codex"))
    end)
    it("includes model flag when provided", function()
      assert.same(
        { "codex", "exec", "--sandbox=read-only", "--model", "model", "--" },
        codex_cli.build_cmd("codex", "model")
      )
    end)
  end)
end)
