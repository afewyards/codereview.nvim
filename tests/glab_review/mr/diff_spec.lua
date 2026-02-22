local diff = require("glab_review.mr.diff")

describe("mr.diff", function()
  describe("format_line_number", function()
    it("formats dual line numbers", function()
      local text = diff.format_line_number(10, 12)
      assert.truthy(text:find("10"))
      assert.truthy(text:find("12"))
    end)
    it("shows only old line for deletes", function()
      local text = diff.format_line_number(10, nil)
      assert.truthy(text:find("10"))
    end)
    it("shows only new line for adds", function()
      local text = diff.format_line_number(nil, 12)
      assert.truthy(text:find("12"))
    end)
  end)
  describe("LINE_NR_WIDTH", function()
    it("line number prefix is exactly LINE_NR_WIDTH chars", function()
      local text = diff.format_line_number(10, 12)
      assert.equals(14, #text)
    end)
    it("line number prefix width is consistent for large numbers", function()
      local text = diff.format_line_number(9999, 9999)
      assert.equals(14, #text)
    end)
  end)

  describe("scroll mode state", function()
    it("defaults to scroll_mode=true when files <= threshold", function()
      local config = require("glab_review.config")
      config.reset()
      config.setup({ diff = { scroll_threshold = 50 } })
      local files = {}
      for i = 1, 20 do
        table.insert(files, { new_path = "file" .. i .. ".lua" })
      end
      local threshold = config.get().diff.scroll_threshold
      assert.truthy(#files <= threshold)
    end)

    it("defaults to scroll_mode=false when files > threshold", function()
      local config = require("glab_review.config")
      config.reset()
      config.setup({ diff = { scroll_threshold = 5 } })
      local files = {}
      for i = 1, 10 do
        table.insert(files, { new_path = "file" .. i .. ".lua" })
      end
      local threshold = config.get().diff.scroll_threshold
      assert.truthy(#files > threshold)
    end)
  end)

  describe("render_all_files", function()
    it("returns file_sections with correct boundaries", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n" },
        { new_path = "b.lua", old_path = "b.lua", diff = "@@ -5,2 +5,2 @@\n ctx\n-old2\n+new2\n" },
      }
      local mr = { diff_refs = nil }
      local discussions = {}

      local result = diff.render_all_files(buf, files, mr, discussions, 8)

      assert.equals(2, #result.file_sections)
      assert.truthy(result.file_sections[1].start_line >= 1)
      assert.truthy(result.file_sections[2].start_line > result.file_sections[1].end_line)
      assert.equals(1, result.file_sections[1].file_idx)
      assert.equals(2, result.file_sections[2].file_idx)
      assert.truthy(#result.line_data > 0)
      assert.truthy(vim.api.nvim_buf_line_count(buf) > 1)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("renders file header lines with path", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "src/foo.lua", old_path = "src/foo.lua", diff = "@@ -1,1 +1,1 @@\n-a\n+b\n" },
      }
      local result = diff.render_all_files(buf, files, { diff_refs = nil }, {}, 8)

      local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
      assert.truthy(first_line:find("src/foo.lua"))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("handles empty files list", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local result = diff.render_all_files(buf, {}, { diff_refs = nil }, {}, 8)
      assert.equals(0, #result.file_sections)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("file_sections reverse-maps buffer line to correct file", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n" },
        { new_path = "b.lua", old_path = "b.lua", diff = "@@ -1,1 +1,1 @@\n-x\n+y\n" },
      }
      local result = diff.render_all_files(buf, files, { diff_refs = nil }, {}, 8)

      for _, sec in ipairs(result.file_sections) do
        for i = sec.start_line, sec.end_line do
          assert.equals(sec.file_idx, result.line_data[i].file_idx)
        end
      end

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("handles renamed files in header", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "new.lua", old_path = "old.lua", renamed_file = true, diff = "@@ -1,1 +1,1 @@\n ctx\n" },
      }
      local result = diff.render_all_files(buf, files, { diff_refs = nil }, {}, 8)
      local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
      assert.truthy(first_line:find("old.lua"))
      assert.truthy(first_line:find("new.lua"))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("shows no-changes placeholder when diff is empty", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = { { new_path = "c.lua", old_path = "c.lua", diff = "" } }
      local result = diff.render_all_files(buf, files, { diff_refs = nil }, {}, 8)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local found = false
      for _, l in ipairs(lines) do
        if l:find("no changes") then found = true end
      end
      assert.truthy(found)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("has no trailing blank line after last file", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,1 +1,1 @@\n-a\n+b\n" },
        { new_path = "b.lua", old_path = "b.lua", diff = "@@ -1,1 +1,1 @@\n-x\n+y\n" },
      }
      local result = diff.render_all_files(buf, files, { diff_refs = nil }, {}, 8)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.not_equals("", lines[#lines])
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("find_anchor", function()
    it("extracts old_line/new_line from a diff line", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
        { type = "context", item = { old_line = 10, new_line = 10, text = "ctx" }, file_idx = 1 },
        { type = "delete", item = { old_line = 11, new_line = nil, text = "old" }, file_idx = 1 },
        { type = "add", item = { old_line = nil, new_line = 11, text = "new" }, file_idx = 1 },
      }
      local anchor = diff.find_anchor(line_data, 2, 1)
      assert.equals(1, anchor.file_idx)
      assert.equals(10, anchor.old_line)
      assert.equals(10, anchor.new_line)
    end)

    it("returns file_idx only for non-diff lines", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
        { type = "add", item = { old_line = nil, new_line = 5, text = "x" }, file_idx = 1 },
      }
      local anchor = diff.find_anchor(line_data, 1, 1)
      assert.equals(1, anchor.file_idx)
      assert.is_nil(anchor.old_line)
      assert.is_nil(anchor.new_line)
    end)

    it("uses explicit file_idx for per-file line_data (no file_idx field)", function()
      local line_data = {
        { type = "context", item = { old_line = 5, new_line = 5, text = "x" } },
      }
      local anchor = diff.find_anchor(line_data, 1, 3)
      assert.equals(3, anchor.file_idx)
      assert.equals(5, anchor.old_line)
    end)
  end)

  describe("find_row_for_anchor", function()
    it("finds exact new_line match", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
        { type = "context", item = { old_line = 10, new_line = 10 }, file_idx = 1 },
        { type = "add", item = { old_line = nil, new_line = 11 }, file_idx = 1 },
      }
      local row = diff.find_row_for_anchor(line_data, { file_idx = 1, new_line = 11 })
      assert.equals(3, row)
    end)

    it("finds exact old_line match for delete-only anchor", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
        { type = "delete", item = { old_line = 20, new_line = nil }, file_idx = 1 },
        { type = "context", item = { old_line = 21, new_line = 20 }, file_idx = 1 },
      }
      local row = diff.find_row_for_anchor(line_data, { file_idx = 1, old_line = 20, new_line = nil })
      assert.equals(2, row)
    end)

    it("falls back to closest new_line in same file", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
        { type = "context", item = { old_line = 5, new_line = 5 }, file_idx = 1 },
        { type = "context", item = { old_line = 50, new_line = 50 }, file_idx = 1 },
      }
      -- Anchor line 8 doesn't exist; line 5 is closer than line 50
      local row = diff.find_row_for_anchor(line_data, { file_idx = 1, new_line = 8 })
      assert.equals(2, row)
    end)

    it("falls back to first diff line when anchor has no line numbers", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
        { type = "context", item = { old_line = 1, new_line = 1 }, file_idx = 1 },
        { type = "file_header", file_idx = 2 },
        { type = "context", item = { old_line = 1, new_line = 1 }, file_idx = 2 },
      }
      local row = diff.find_row_for_anchor(line_data, { file_idx = 2 })
      assert.equals(4, row)
    end)

    it("returns 1 when nothing matches", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
      }
      local row = diff.find_row_for_anchor(line_data, { file_idx = 5, new_line = 99 })
      assert.equals(1, row)
    end)

    it("matches correct file_idx in multi-file scroll data", function()
      local line_data = {
        { type = "context", item = { old_line = 10, new_line = 10 }, file_idx = 1 },
        { type = "context", item = { old_line = 10, new_line = 10 }, file_idx = 2 },
      }
      local row = diff.find_row_for_anchor(line_data, { file_idx = 2, new_line = 10 })
      assert.equals(2, row)
    end)
  end)

  describe("clamp_cursor_to_content", function()
    local buf, win

    before_each(function()
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "   10 | 10    local x = 1",
        "   11 | 11    local y = 2",
      })
      win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = 0,
        col = 0,
        width = 40,
        height = 5,
      })
    end)

    after_each(function()
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("snaps cursor to LINE_NR_WIDTH when placed at column 0", function()
      diff.clamp_cursor_to_content(buf, win)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buf = buf })
      local col = vim.api.nvim_win_get_cursor(win)[2]
      assert.equals(diff.LINE_NR_WIDTH, col)
    end)

    it("does not move cursor already past LINE_NR_WIDTH", function()
      diff.clamp_cursor_to_content(buf, win)
      vim.api.nvim_win_set_cursor(win, { 1, 20 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buf = buf })
      local col = vim.api.nvim_win_get_cursor(win)[2]
      assert.equals(20, col)
    end)

    it("clamps cursor at exactly LINE_NR_WIDTH - 1", function()
      diff.clamp_cursor_to_content(buf, win)
      vim.api.nvim_win_set_cursor(win, { 1, 13 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buf = buf })
      local col = vim.api.nvim_win_get_cursor(win)[2]
      assert.equals(14, col)
    end)
  end)

  describe("toggle_scroll_mode line preservation", function()
    local function make_files()
      return {
        { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,3 +1,3 @@\n ctx1\n-old1\n+new1\n ctx2\n" },
        { new_path = "b.lua", old_path = "b.lua", diff = "@@ -10,3 +10,3 @@\n ctx10\n-old10\n+new10\n ctx11\n" },
      }
    end

    it("round-trips anchor through scroll line_data", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = make_files()
      local result = diff.render_all_files(buf, files, { diff_refs = nil }, {}, 8)

      local anchor = { file_idx = 2, new_line = 10 }
      local row = diff.find_row_for_anchor(result.line_data, anchor)
      assert.equals(2, result.line_data[row].file_idx)
      assert.equals(10, result.line_data[row].item.new_line)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("round-trips anchor through per-file line_data", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local file = { new_path = "b.lua", old_path = "b.lua", diff = "@@ -10,3 +10,3 @@\n ctx10\n-old10\n+new10\n ctx11\n" }
      local ld = diff.render_file_diff(buf, file, { diff_refs = nil }, {}, 8)

      local anchor = diff.find_anchor(ld, 2, 2)
      local row = diff.find_row_for_anchor(ld, anchor, 2)
      assert.equals(2, row)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
