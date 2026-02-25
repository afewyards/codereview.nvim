local header = require("codereview.mr.sidebar_components.header")

describe("sidebar_components.header", function()
  describe("render", function()
    it("renders 4 lines with id/title, branches, status, separator", function()
      local review = {
        id = 42,
        title = "Fix authentication bug",
        source_branch = "fix/auth",
        target_branch = "main",
        pipeline_status = "success",
        approved_by = {},
        approvals_required = 0,
        merge_status = "can_be_merged",
      }
      local result = header.render(review, 30)
      assert.equals(4, #result.lines)
      assert.truthy(result.lines[1]:find("#42"))
      assert.truthy(result.lines[1]:find("Fix auth"))
      assert.truthy(result.lines[2]:find("fix/auth"))
      assert.truthy(result.lines[2]:find("main"))
      assert.truthy(result.lines[4]:find("─"))
    end)

    it("shows correct CI icon for each pipeline status", function()
      local statuses = {
        { status = "success", icon = "●" },
        { status = "failed",  icon = "✗" },
        { status = "running", icon = "◐" },
        { status = "pending", icon = "◐" },
      }
      for _, s in ipairs(statuses) do
        local review = {
          id = 1, title = "T", source_branch = "a", target_branch = "b",
          pipeline_status = s.status,
          approved_by = {}, approvals_required = 0,
          merge_status = "can_be_merged",
        }
        local result = header.render(review, 30)
        assert.truthy(
          result.lines[3]:find(s.icon, 1, true),
          "Expected " .. s.icon .. " for status " .. s.status
        )
      end
    end)

    it("shows approvals and conflict indicators", function()
      -- With required approvals and conflicts
      local review = {
        id = 7, title = "WIP",
        source_branch = "feature", target_branch = "main",
        pipeline_status = nil,
        approved_by = { "alice", "bob" },
        approvals_required = 3,
        merge_status = "cannot_be_merged",
      }
      local result = header.render(review, 30)
      assert.truthy(result.lines[3]:find("✓2/3"), "Expected approval indicator ✓2/3")
      assert.truthy(result.lines[3]:find("⚠ Conflicts"), "Expected conflict indicator")

      -- No conflicts, no approvals
      local review2 = {
        id = 8, title = "Clean",
        source_branch = "feat", target_branch = "main",
        pipeline_status = nil,
        approved_by = {}, approvals_required = 0,
        merge_status = "can_be_merged",
      }
      local result2 = header.render(review2, 30)
      assert.truthy(result2.lines[3]:find("◯ No conflicts"), "Expected no-conflict indicator")
    end)
  end)
end)
