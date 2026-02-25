local diff_render = require("codereview.mr.diff_render")

describe("mr.diff_render", function()
  describe("render_all_files", function()
    it("returns file_sections with correct boundaries", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n" },
        { new_path = "b.lua", old_path = "b.lua", diff = "@@ -5,2 +5,2 @@\n ctx\n-old2\n+new2\n" },
      }
      local mr = { diff_refs = nil }
      local discussions = {}

      local result = diff_render.render_all_files(buf, files, mr, discussions, 8)

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
      local result = diff_render.render_all_files(buf, files, { diff_refs = nil }, {}, 8)

      local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
      assert.truthy(first_line:find("src/foo.lua"))

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("handles empty files list", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local result = diff_render.render_all_files(buf, {}, { diff_refs = nil }, {}, 8)
      assert.equals(0, #result.file_sections)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("file_sections reverse-maps buffer line to correct file", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n" },
        { new_path = "b.lua", old_path = "b.lua", diff = "@@ -1,1 +1,1 @@\n-x\n+y\n" },
      }
      local result = diff_render.render_all_files(buf, files, { diff_refs = nil }, {}, 8)

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
      local result = diff_render.render_all_files(buf, files, { diff_refs = nil }, {}, 8)
      local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
      assert.truthy(first_line:find("old.lua"))
      assert.truthy(first_line:find("new.lua"))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("shows no-changes placeholder when diff is empty", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = { { new_path = "c.lua", old_path = "c.lua", diff = "" } }
      local result = diff_render.render_all_files(buf, files, { diff_refs = nil }, {}, 8)
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
      local result = diff_render.render_all_files(buf, files, { diff_refs = nil }, {}, 8)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.not_equals("", lines[#lines])
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("inline virtual text line numbers", function()
    it("buffer lines do not contain line number prefix", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n" },
      }
      local mr = { diff_refs = nil }
      diff_render.render_file_diff(buf, files[1], mr, {}, 8)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      for _, line in ipairs(lines) do
        assert.is_nil(line:match("^%s+%d+%s+|%s+%d+%s+"))
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("extmarks with inline virtual text exist on diff lines", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n" },
      }
      local mr = { diff_refs = nil }
      diff_render.render_file_diff(buf, files[1], mr, {}, 8)
      local ns = vim.api.nvim_create_namespace("codereview_diff")
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      local has_inline_vt = false
      for _, mark in ipairs(marks) do
        local details = mark[4]
        if details.virt_text and details.virt_text_pos == "inline" then
          has_inline_vt = true
          break
        end
      end
      assert.truthy(has_inline_vt)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    pending("yanking a line does not include line number prefix (requires real Neovim)", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor", width = 80, height = 10, row = 0, col = 0,
      })
      local files = {
        { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" },
      }
      diff_render.render_file_diff(buf, files[1], { diff_refs = nil }, {}, 8)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local target_row
      for i, l in ipairs(lines) do
        if l == "new" then target_row = i break end
      end
      assert.truthy(target_row)
      vim.api.nvim_win_set_cursor(win, { target_row, 0 })
      vim.cmd("normal! yy")
      local reg = vim.fn.getreg('"')
      assert.equals("new\n", reg)
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
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
      local result = diff_render.render_all_files(buf, files, { diff_refs = nil }, {}, 8)

      local anchor = { file_idx = 2, new_line = 10 }
      -- Use diff module's find_row_for_anchor for the round-trip test
      local diff = require("codereview.mr.diff")
      local row = diff.find_row_for_anchor(result.line_data, anchor)
      assert.equals(2, result.line_data[row].file_idx)
      assert.equals(10, result.line_data[row].item.new_line)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("round-trips anchor through per-file line_data", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local file = { new_path = "b.lua", old_path = "b.lua", diff = "@@ -10,3 +10,3 @@\n ctx10\n-old10\n+new10\n ctx11\n" }
      local ld = diff_render.render_file_diff(buf, file, { diff_refs = nil }, {}, 8)

      local diff = require("codereview.mr.diff")
      local anchor = diff.find_anchor(ld, 2, 2)
      local row = diff.find_row_for_anchor(ld, anchor, 2)
      assert.equals(2, row)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
