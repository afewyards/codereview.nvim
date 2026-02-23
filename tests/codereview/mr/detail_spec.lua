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
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
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
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("approved"))
    end)

    it("returns structured result with lines, highlights, and row_map", function()
      local discussions = {
        {
          id = "abc",
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
      local result = detail.build_activity_lines(discussions)
      assert.is_table(result.lines)
      assert.is_table(result.highlights)
      assert.is_table(result.row_map)
    end)

    it("renders comment thread with box-drawing chars", function()
      local discussions = {
        {
          id = "abc",
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
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      -- Box header with author
      assert.truthy(joined:find("┌"))
      assert.truthy(joined:find("@jan"))
      -- Body line
      assert.truthy(joined:find("│ Looks good"))
      -- Footer with resolved keymap labels (defaults: r, gt)
      assert.truthy(joined:find("└"))
      assert.truthy(joined:find("reply"))
      assert.truthy(joined:find("resolve"))
    end)

    it("renders replies with arrow notation", function()
      local discussions = {
        {
          id = "abc",
          notes = {
            {
              id = 1,
              body = "Fix this",
              author = "alice",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
            },
            {
              id = 2,
              body = "Done",
              author = "bob",
              created_at = "2026-02-20T11:00:00Z",
              system = false,
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("↪"))
      assert.truthy(joined:find("@bob"))
      assert.truthy(joined:find("Done"))
    end)

    it("includes resolved/unresolved status in header", function()
      local discussions = {
        {
          id = "abc",
          resolved = false,
          notes = {
            {
              id = 1,
              body = "Bug here",
              author = "alice",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
              resolvable = true,
              resolved = false,
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("Unresolved"))
    end)

    it("maps thread rows to discussions in row_map", function()
      local disc = {
        id = "abc",
        notes = {
          {
            id = 1,
            body = "Comment",
            author = "jan",
            created_at = "2026-02-20T10:00:00Z",
            system = false,
          },
        },
      }
      local result = detail.build_activity_lines({ disc })
      -- Find at least one row_map entry pointing to this discussion
      local found = false
      for _, entry in pairs(result.row_map) do
        if entry.discussion and entry.discussion.id == "abc" then
          found = true
          break
        end
      end
      assert.is_true(found)
    end)

    it("skips inline discussions (with position)", function()
      local discussions = {
        {
          id = "abc",
          notes = {
            {
              id = 1,
              body = "Inline note",
              author = "jan",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
              position = { new_path = "foo.lua", new_line = 10 },
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.falsy(joined:find("Inline note"))
    end)

    it("still renders system notes as simple lines", function()
      local discussions = {
        {
          id = "def",
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
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("approved"))
      -- System notes should NOT have box drawing
      assert.falsy(joined:find("┌"))
    end)
  end)
end)
