local list = require("codereview.mr.list")

describe("mr.list", function()
  describe("format_mr_entry", function()
    it("formats MR for picker display", function()
      local review = {
        id = 42,
        title = "Fix auth",
        author = "maria",
        source_branch = "fix/auth",
        pipeline_status = "success",
        upvotes = 1,
        approvals_required = 2,
      }
      local entry = list.format_mr_entry(review)
      assert.truthy(entry.display:find("#42"))
      assert.truthy(entry.display:find("Fix auth"))
      assert.truthy(entry.display:find("maria"))
      assert.equals(42, entry.id)
    end)

    it("handles MR without pipeline", function()
      local review = {
        id = 10,
        title = "Draft: WIP",
        author = "jan",
        source_branch = "wip",
        pipeline_status = nil,
      }
      local entry = list.format_mr_entry(review)
      assert.truthy(entry.display:find("#10"))
    end)
  end)

  describe("pipeline_icon", function()
    it("returns check for success", function()
      assert.equals("[ok]", list.pipeline_icon("success"))
    end)
    it("returns x for failed", function()
      assert.equals("[fail]", list.pipeline_icon("failed"))
    end)
    it("returns ... for running", function()
      assert.equals("[..]", list.pipeline_icon("running"))
    end)
    it("returns ? for nil", function()
      assert.equals("[--]", list.pipeline_icon(nil))
    end)
  end)
end)
