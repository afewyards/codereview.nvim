local tracker = require("codereview.mr.review_tracker")

describe("mr.review_tracker", function()
  describe("init_file", function()
    it("returns correct structure with hunks from line_data", function()
      local line_data = {
        { type = "add",     item = { hunk_idx = 1, text = "+foo" } },
        { type = "context", item = { hunk_idx = 1, text = " bar" } },
        { type = "add",     item = { hunk_idx = 2, text = "+baz" } },
        { type = "delete",  item = { hunk_idx = 2, text = "-qux" } },
      }
      local status = tracker.init_file("src/foo.lua", line_data, nil)
      assert.equals("src/foo.lua", status.path)
      assert.equals(2, status.hunks_total)
      assert.equals(0, status.hunks_seen)
      assert.same({}, status.seen)
      assert.equals("unvisited", status.status)
      -- row 1 and row 3 are hunk start rows
      assert.equals(1, status.hunk_rows[1])
      assert.equals(2, status.hunk_rows[3])
    end)

    it("filters by file_idx in scroll mode", function()
      local line_data = {
        { type = "add", item = { hunk_idx = 1, text = "+a" }, file_idx = 1 },
        { type = "add", item = { hunk_idx = 1, text = "+b" }, file_idx = 2 },
        { type = "add", item = { hunk_idx = 2, text = "+c" }, file_idx = 2 },
      }
      local status = tracker.init_file("b.lua", line_data, 2)
      assert.equals(2, status.hunks_total)
      -- row 2 is first line for file_idx=2, row 3 starts hunk 2
      assert.truthy(status.hunk_rows[2])
      assert.truthy(status.hunk_rows[3])
    end)
  end)

  describe("mark_visible", function()
    it("marks hunks in viewport as seen and transitions status", function()
      local line_data = {
        { type = "add",     item = { hunk_idx = 1, text = "+foo" } },
        { type = "context", item = { hunk_idx = 1, text = " bar" } },
        { type = "add",     item = { hunk_idx = 2, text = "+baz" } },
      }
      local status = tracker.init_file("src/foo.lua", line_data, nil)
      -- Viewport covering only row 1 (hunk 1 start)
      local changed = tracker.mark_visible(status, 1, 2)
      assert.is_true(changed)
      assert.equals(1, status.hunks_seen)
      assert.equals("partial", status.status)
      assert.is_true(status.seen[1])
      assert.is_nil(status.seen[2])
    end)

    it("transitions to reviewed when all hunks are seen", function()
      local line_data = {
        { type = "add", item = { hunk_idx = 1, text = "+foo" } },
        { type = "add", item = { hunk_idx = 2, text = "+bar" } },
      }
      local status = tracker.init_file("src/foo.lua", line_data, nil)
      -- First pass: see hunk 1
      tracker.mark_visible(status, 1, 1)
      assert.equals("partial", status.status)
      -- Second pass: see hunk 2
      local changed = tracker.mark_visible(status, 2, 2)
      assert.is_true(changed)
      assert.equals(2, status.hunks_seen)
      assert.equals("reviewed", status.status)
    end)

    it("returns false when no new hunks are seen", function()
      local line_data = {
        { type = "add", item = { hunk_idx = 1, text = "+foo" } },
      }
      local status = tracker.init_file("src/foo.lua", line_data, nil)
      tracker.mark_visible(status, 1, 1)
      -- Call again on same viewport
      local changed = tracker.mark_visible(status, 1, 1)
      assert.is_false(changed)
    end)
  end)
end)
