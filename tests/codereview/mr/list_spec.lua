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
      list.format_entries({ entry })
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
      list.format_entries({ entry })
      assert.truthy(entry.display:find("#10"))
    end)
  end)

  describe("format_entries returns widths", function()
    it("returns computed column widths", function()
      local review1 = {
        id = 1,
        title = "Short",
        author = "ab",
        source_branch = "a",
        pipeline_status = "success",
      }
      local review2 = {
        id = 123,
        title = "Longer title here",
        author = "alice",
        source_branch = "b",
        pipeline_status = "failed",
      }
      local e1 = list.format_mr_entry(review1)
      local e2 = list.format_mr_entry(review2)
      local widths = list.format_entries({ e1, e2 })
      assert.is_table(widths)
      assert.equals(70, widths.title)
      assert.equals(5, widths.author)
      assert.equals(3, widths.id)
      assert.equals(6, widths.icon)
    end)
  end)

  describe("format_mr_preview", function()
    it("formats preview with title, branch, time, and description", function()
      local entry = {
        title = "Fix auth bug",
        source_branch = "fix/auth",
        time_str = "2h ago",
        review = { description = "This fixes the auth issue" },
      }
      local text = list.format_mr_preview(entry)
      assert.truthy(text:find("# Fix auth bug"))
      assert.truthy(text:find("%*%*Branch:%*%*"))
      assert.truthy(text:find("fix/auth"))
      assert.truthy(text:find("2h ago"))
      assert.truthy(text:find("This fixes the auth issue"))
    end)

    it("shows (no description) when description is empty", function()
      local entry = {
        title = "WIP",
        source_branch = "wip/feature",
        time_str = "1d ago",
        review = { description = "" },
      }
      local text = list.format_mr_preview(entry)
      assert.truthy(text:find("%(no description%)"))
    end)

    it("handles nil review", function()
      local entry = {
        title = "Draft",
        source_branch = "draft/x",
        time_str = "3h ago",
        review = nil,
      }
      local text = list.format_mr_preview(entry)
      assert.truthy(text:find("%(no description%)"))
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
