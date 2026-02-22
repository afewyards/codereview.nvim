local comment = require("glab_review.mr.comment")
describe("mr.comment", function()
  describe("build_thread_lines", function()
    it("formats a discussion thread", function()
      local disc = {
        id = "abc",
        notes = {
          { author = { username = "jan" }, body = "Should we make this configurable?", created_at = "2026-02-20T10:00:00Z", resolvable = true, resolved = false },
          { author = { username = "maria" }, body = "Good point, will add.", created_at = "2026-02-20T11:00:00Z", resolvable = false, resolved = false },
        },
      }
      local lines = comment.build_thread_lines(disc)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("configurable"))
      assert.truthy(joined:find("maria"))
    end)
    it("shows resolved status", function()
      local disc = {
        id = "def",
        notes = {
          { author = { username = "jan" }, body = "LGTM", created_at = "2026-02-20T10:00:00Z", resolvable = true, resolved = true, resolved_by = { username = "jan" } },
        },
      }
      local lines = comment.build_thread_lines(disc)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Resolved"))
    end)
  end)
end)
