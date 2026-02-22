local detail = require("codereview.mr.detail")

describe("mr.detail", function()
  describe("build_header_lines", function()
    it("builds header from normalized review data", function()
      local review = {
        id = 42,
        title = "Fix auth token refresh",
        author = "maria",
        source_branch = "fix/token-refresh",
        target_branch = "main",
        state = "opened",
        pipeline_status = "success",
        description = "Fixes the bug",
        web_url = "https://gitlab.com/group/project/-/merge_requests/42",
        approved_by = { "reviewer1" },
        approvals_required = 2,
      }
      local lines = detail.build_header_lines(review)
      assert.truthy(#lines > 0)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("#42"))
      assert.truthy(joined:find("Fix auth token refresh"))
      assert.truthy(joined:find("maria"))
      assert.truthy(joined:find("Approvals"))
    end)
  end)

  describe("build_activity_lines", function()
    it("formats general discussion threads", function()
      local discussions = {
        {
          id = "abc",
          individual_note = true,
          notes = {
            {
              id = 1,
              body = "Looks good!",
              author = "jan",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
            },
          },
        },
      }
      local lines = detail.build_activity_lines(discussions)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("Looks good"))
    end)

    it("formats system notes as compact lines", function()
      local discussions = {
        {
          id = "def",
          individual_note = true,
          notes = {
            {
              id = 2,
              body = "approved this merge request",
              author = "jan",
              created_at = "2026-02-20T11:00:00Z",
              system = true,
            },
          },
        },
      }
      local lines = detail.build_activity_lines(discussions)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("approved"))
    end)
  end)
end)
