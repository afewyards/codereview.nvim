local state = require("codereview.pipeline.state")

describe("pipeline.state", function()
  describe("create", function()
    it("creates state with required fields", function()
      local s = state.create({
        review = { id = 1 },
        provider = { name = "gitlab" },
        client = {},
        ctx = { base_url = "url", project = "p" },
      })
      assert.truthy(s.review)
      assert.truthy(s.provider)
      assert.is_nil(s.pipeline)
      assert.same({}, s.jobs)
      assert.same({}, s.stages)
      assert.same({}, s.collapsed)
    end)
  end)

  describe("group_by_stage", function()
    it("groups jobs into ordered stages", function()
      local jobs = {
        { id = 1, name = "build", stage = "build", status = "success" },
        { id = 2, name = "lint", stage = "test", status = "running" },
        { id = 3, name = "unit", stage = "test", status = "pending" },
        { id = 4, name = "deploy", stage = "deploy", status = "manual" },
      }
      local stages = state.group_by_stage(jobs)
      assert.equal(3, #stages)
      assert.equal("build", stages[1].name)
      assert.equal(1, #stages[1].jobs)
      assert.equal("test", stages[2].name)
      assert.equal(2, #stages[2].jobs)
      assert.equal("deploy", stages[3].name)
    end)
  end)

  describe("is_terminal", function()
    it("returns true for success", function()
      assert.is_true(state.is_terminal("success"))
    end)
    it("returns true for failed", function()
      assert.is_true(state.is_terminal("failed"))
    end)
    it("returns false for running", function()
      assert.is_false(state.is_terminal("running"))
    end)
    it("returns false for pending", function()
      assert.is_false(state.is_terminal("pending"))
    end)
  end)

  describe("format_duration", function()
    it("formats seconds to Xm Ys", function()
      assert.equal("2m 03s", state.format_duration(123))
    end)
    it("formats zero", function()
      assert.equal("0m 00s", state.format_duration(0))
    end)
    it("formats hours", function()
      assert.equal("1h 05m", state.format_duration(3900))
    end)
  end)
end)
