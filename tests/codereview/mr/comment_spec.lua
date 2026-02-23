local comment = require("codereview.mr.comment")
describe("mr.comment", function()
  describe("open_input_popup opts", function()
    it("module loads without error", function()
      assert.is_table(comment)
    end)
  end)

  describe("build_thread_lines", function()
    it("formats a discussion thread", function()
      local disc = {
        id = "abc",
        notes = {
          { author = "jan", body = "Should we make this configurable?", created_at = "2026-02-20T10:00:00Z", resolvable = true, resolved = false },
          { author = "maria", body = "Good point, will add.", created_at = "2026-02-20T11:00:00Z", resolvable = false, resolved = false },
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
          { author = "jan", body = "LGTM", created_at = "2026-02-20T10:00:00Z", resolvable = true, resolved = true, resolved_by = "jan" },
        },
      }
      local lines = comment.build_thread_lines(disc)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Resolved"))
    end)
  end)

  describe("post_with_retry", function()
    it("calls on_success on first success", function()
      local called = false
      comment.post_with_retry(
        function() return nil, nil end,
        function() called = true end,
        function() end
      )
      vim.wait(100, function() return called end)
      assert.truthy(called)
    end)

    it("calls on_failure after max retries", function()
      local failed = false
      comment.post_with_retry(
        function() return nil, "server error" end,
        function() end,
        function() failed = true end,
        { max_retries = 1, delay_ms = 10 }
      )
      vim.wait(500, function() return failed end)
      assert.truthy(failed)
    end)
  end)
end)
