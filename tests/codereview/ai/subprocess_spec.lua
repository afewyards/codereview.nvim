-- tests/codereview/ai/subprocess_spec.lua
local subprocess = require("codereview.ai.subprocess")

describe("ai.subprocess", function()
  describe("build_cmd", function()
    it("builds default claude command", function()
      local cmd = subprocess.build_cmd("claude")
      assert.same({ "claude", "-p" }, cmd)
    end)

    it("uses custom command", function()
      local cmd = subprocess.build_cmd("/usr/local/bin/claude")
      assert.same({ "/usr/local/bin/claude", "-p" }, cmd)
    end)
  end)
end)
