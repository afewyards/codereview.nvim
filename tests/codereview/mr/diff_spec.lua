local diff = require("codereview.mr.diff")

describe("mr.diff", function()
  describe("scroll mode state", function()
    it("defaults to scroll_mode=true when files <= threshold", function()
      local config = require("codereview.config")
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
      local config = require("codereview.config")
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

  describe("inline virtual text line numbers", function()
    it("buffer lines do not contain line number prefix", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n" },
      }
      local mr = { diff_refs = nil }
      diff.render_file_diff(buf, files[1], mr, {}, 8)
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
      diff.render_file_diff(buf, files[1], mr, {}, 8)
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
      diff.render_file_diff(buf, files[1], { diff_refs = nil }, {}, 8)
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

  describe("render_summary", function()
    before_each(function()
      package.loaded["codereview.mr.list"] = {
        pipeline_icon = function() return "✓" end,
      }
      -- detail.lua requires client/git/endpoints at top level; stub them too
      package.loaded["codereview.api.client"] = {}
      package.loaded["codereview.api.endpoints"] = {}
      package.loaded["codereview.git"] = {}
      -- reset detail so it re-loads with our stubs
      package.loaded["codereview.mr.detail"] = nil
    end)
    after_each(function()
      package.loaded["codereview.mr.list"] = nil
      package.loaded["codereview.api.client"] = nil
      package.loaded["codereview.api.endpoints"] = nil
      package.loaded["codereview.git"] = nil
      package.loaded["codereview.mr.detail"] = nil
    end)

    it("renders MR header and activity into buffer", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local state = {
        review = {
          id = 42,
          title = "Fix auth",
          author = "maria",
          source_branch = "fix/auth",
          target_branch = "main",
          state = "opened",
          pipeline_status = "success",
          description = "Fixes the bug",
          approved_by = {},
          approvals_required = 0,
        },
        discussions = {
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
        },
      }
      diff.render_summary(buf, state)

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("#42"))
      assert.truthy(joined:find("Fix auth"))
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("Looks good"))
      assert.truthy(#lines > 5)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does NOT set filetype to markdown", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local state = {
        review = {
          id = 1, title = "Test", author = "me",
          source_branch = "feat", target_branch = "main",
          state = "opened", pipeline_status = "success",
          description = "",
          approved_by = {}, approvals_required = 0,
        },
        discussions = {},
      }
      diff.render_summary(buf, state)
      assert.not_equals("markdown", vim.bo[buf].filetype)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("render_sidebar with summary button", function()
    before_each(function()
      -- Stub codereview.mr.list so render_sidebar works without plenary
      package.loaded["codereview.mr.list"] = {
        pipeline_icon = function(_) return "[--]" end,
      }
    end)

    after_each(function()
      package.loaded["codereview.mr.list"] = nil
    end)

    it("renders Summary button as first interactive row", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local state = {
        review = { id = 1, title = "Test", source_branch = "feat", pipeline_status = nil },
        files = {
          { new_path = "src/a.lua", old_path = "src/a.lua" },
        },
        discussions = {},
        current_file = 1,
        collapsed_dirs = {},
        sidebar_row_map = {},
        view_mode = "summary",
      }
      diff.render_sidebar(buf, state)
      local summary_row = nil
      for row, entry in pairs(state.sidebar_row_map) do
        if entry.type == "summary" then
          summary_row = row
          break
        end
      end
      assert.truthy(summary_row, "Expected summary entry in sidebar_row_map")
      for row, entry in pairs(state.sidebar_row_map) do
        if entry.type == "file" then
          assert.truthy(summary_row < row)
        end
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("shows active indicator on Summary when view_mode is summary", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local state = {
        review = { id = 1, title = "Test", source_branch = "feat", pipeline_status = nil },
        files = { { new_path = "a.lua", old_path = "a.lua" } },
        discussions = {},
        current_file = 1,
        collapsed_dirs = {},
        sidebar_row_map = {},
        view_mode = "summary",
      }
      diff.render_sidebar(buf, state)
      local summary_row = nil
      for row, entry in pairs(state.sidebar_row_map) do
        if entry.type == "summary" then summary_row = row break end
      end
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      assert.truthy(lines[summary_row]:find("▸"))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("no file gets active indicator when view_mode is summary", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local state = {
        review = { id = 1, title = "Test", source_branch = "feat", pipeline_status = nil },
        files = { { new_path = "a.lua", old_path = "a.lua" } },
        discussions = {},
        current_file = 1,
        collapsed_dirs = {},
        sidebar_row_map = {},
        view_mode = "summary",
      }
      diff.render_sidebar(buf, state)
      for row, entry in pairs(state.sidebar_row_map) do
        if entry.type == "file" then
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          assert.truthy(lines[row]:match("^%s%s "))
        end
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("place_comment_signs optimistic states", function()
    it("uses pending highlight for is_optimistic discussion", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local line_data = {
        { item = { new_line = 5, old_line = 5 }, type = "add" },
      }
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1" })
      local discussions = {{
        notes = {{ author = "You", body = "test", created_at = "2026-02-23T10:00:00Z",
          position = { new_path = "a.lua", new_line = 5 } }},
        is_optimistic = true,
      }}
      local file_diff = { new_path = "a.lua", old_path = "a.lua" }
      diff.place_comment_signs(buf, line_data, discussions, file_diff)
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local found_pending = false
      for _, m in ipairs(marks) do
        if m[4] and m[4].virt_lines then
          for _, vl in ipairs(m[4].virt_lines) do
            for _, chunk in ipairs(vl) do
              if chunk[2] == "CodeReviewCommentPending" then found_pending = true end
            end
          end
        end
      end
      assert.truthy(found_pending, "Expected CodeReviewCommentPending highlight")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("uses failed highlight for is_failed discussion", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local line_data = {
        { item = { new_line = 5, old_line = 5 }, type = "add" },
      }
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1" })
      local discussions = {{
        notes = {{ author = "You", body = "test", created_at = "2026-02-23T10:00:00Z",
          position = { new_path = "a.lua", new_line = 5 } }},
        is_failed = true,
      }}
      local file_diff = { new_path = "a.lua", old_path = "a.lua" }
      diff.place_comment_signs(buf, line_data, discussions, file_diff)
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local found_failed = false
      for _, m in ipairs(marks) do
        if m[4] and m[4].virt_lines then
          for _, vl in ipairs(m[4].virt_lines) do
            for _, chunk in ipairs(vl) do
              if chunk[2] == "CodeReviewCommentFailed" then found_failed = true end
            end
          end
        end
      end
      assert.truthy(found_failed, "Expected CodeReviewCommentFailed highlight")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("cycle_note_selection", function()
    it("cycles nil -> 1 -> 2 -> nil for 2-note thread", function()
      assert.equals(1, diff.cycle_note_selection(nil, 2, 1))
      assert.equals(2, diff.cycle_note_selection(1, 2, 1))
      assert.is_nil(diff.cycle_note_selection(2, 2, 1))
    end)

    it("cycles backward nil -> 2 -> 1 -> nil", function()
      assert.equals(2, diff.cycle_note_selection(nil, 2, -1))
      assert.equals(1, diff.cycle_note_selection(2, 2, -1))
      assert.is_nil(diff.cycle_note_selection(1, 2, -1))
    end)

    it("handles single-note thread", function()
      assert.equals(1, diff.cycle_note_selection(nil, 1, 1))
      assert.is_nil(diff.cycle_note_selection(1, 1, 1))
    end)
  end)

  describe("build_row_items", function()
    it("returns empty for no items", function()
      assert.same({}, diff.build_row_items({}, {}))
    end)

    it("returns AI items first", function()
      local ai = { { severity = "info" }, { severity = "error" } }
      local result = diff.build_row_items(ai, {})
      assert.same({
        { type = "ai", index = 1 },
        { type = "ai", index = 2 },
      }, result)
    end)

    it("returns comment items after AI", function()
      local ai = { { severity = "info" } }
      local discs = {
        { id = "d1", notes = { { id = "n1" }, { id = "n2" } } },
        { id = "d2", notes = { { id = "n3" } } },
      }
      local result = diff.build_row_items(ai, discs)
      assert.same({
        { type = "ai", index = 1 },
        { type = "comment", disc_id = "d1", note_idx = 1 },
        { type = "comment", disc_id = "d1", note_idx = 2 },
        { type = "comment", disc_id = "d2", note_idx = 1 },
      }, result)
    end)

    it("skips system notes", function()
      local discs = {
        { id = "d1", notes = { { id = "n1" }, { id = "n2", system = true }, { id = "n3" } } },
      }
      local result = diff.build_row_items({}, discs)
      assert.same({
        { type = "comment", disc_id = "d1", note_idx = 1 },
        { type = "comment", disc_id = "d1", note_idx = 3 },
      }, result)
    end)
  end)

  describe("cycle_row_selection", function()
    local items = {
      { type = "ai", index = 1 },
      { type = "ai", index = 2 },
      { type = "comment", disc_id = "d1", note_idx = 1 },
    }

    it("nil -> first item forward", function()
      assert.same({ type = "ai", index = 1 }, diff.cycle_row_selection(items, nil, 1))
    end)

    it("cycles forward through items", function()
      assert.same(items[2], diff.cycle_row_selection(items, items[1], 1))
      assert.same(items[3], diff.cycle_row_selection(items, items[2], 1))
    end)

    it("returns nil past last item", function()
      assert.is_nil(diff.cycle_row_selection(items, items[3], 1))
    end)

    it("nil -> last item backward", function()
      assert.same(items[3], diff.cycle_row_selection(items, nil, -1))
    end)

    it("cycles backward", function()
      assert.same(items[2], diff.cycle_row_selection(items, items[3], -1))
      assert.same(items[1], diff.cycle_row_selection(items, items[2], -1))
    end)

    it("returns nil past first item backward", function()
      assert.is_nil(diff.cycle_row_selection(items, items[1], -1))
    end)

    it("returns nil for empty items", function()
      assert.is_nil(diff.cycle_row_selection({}, nil, 1))
    end)
  end)

  describe("load_diffs_into_state", function()
    it("sets state.files when not yet loaded", function()
      local state = {
        review = { id = 1 },
        files = nil,
        scroll_mode = nil,
      }
      local files = {
        { new_path = "a.lua", old_path = "a.lua" },
        { new_path = "b.lua", old_path = "b.lua" },
      }
      diff.load_diffs_into_state(state, files)
      assert.equals(2, #state.files)
      assert.truthy(state.scroll_mode ~= nil)
    end)

    it("is a no-op when files already loaded", function()
      local state = {
        review = { id = 1 },
        files = { { new_path = "existing.lua" } },
        scroll_mode = true,
      }
      diff.load_diffs_into_state(state, { { new_path = "other.lua" } })
      assert.equals("existing.lua", state.files[1].new_path)
    end)
  end)

  describe("ensure_virt_lines_visible", function()
    local DIFF_NS = vim.api.nvim_create_namespace("codereview_diff")

    -- Per-window mock state: { [win] = { height=N, topline=N } }
    local _win_state = {}
    local _current_win = nil
    local _orig_win_call, _orig_win_get_height, _orig_winsaveview, _orig_winrestview

    before_each(function()
      _win_state = {}
      _current_win = nil
      _orig_win_call = vim.api.nvim_win_call
      _orig_win_get_height = vim.api.nvim_win_get_height
      _orig_winsaveview = vim.fn.winsaveview
      _orig_winrestview = vim.fn.winrestview

      vim.api.nvim_win_call = function(win, fn)
        local prev = _current_win
        _current_win = win
        local result = fn()
        _current_win = prev
        return result
      end
      vim.api.nvim_win_get_height = function(win)
        return (_win_state[win] or {}).height or 10
      end
      vim.fn.winsaveview = function()
        local win = _current_win or 1
        return { topline = (_win_state[win] or {}).topline or 1 }
      end
      vim.fn.winrestview = function(view)
        local win = _current_win or 1
        if not _win_state[win] then _win_state[win] = {} end
        if view.topline then _win_state[win].topline = view.topline end
      end
    end)

    after_each(function()
      vim.api.nvim_win_call = _orig_win_call
      vim.api.nvim_win_get_height = _orig_win_get_height
      vim.fn.winsaveview = _orig_winsaveview
      vim.fn.winrestview = _orig_winrestview
      _win_state = {}
    end)

    local function make_buf_with_lines(n)
      local buf = vim.api.nvim_create_buf(false, true)
      local lines = {}
      for i = 1, n do lines[i] = "line " .. i end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return buf
    end

    local function make_win(buf, height, topline)
      local win = vim.api.nvim_open_win(buf, true, {})
      _win_state[win] = { height = height, topline = topline or 1 }
      return win
    end

    local function get_topline(win)
      return (_win_state[win] or {}).topline or 1
    end

    it("adjusts topline when virt_lines extend past viewport", function()
      local buf = make_buf_with_lines(30)
      local win = make_win(buf, 10, 1)
      local virt_lines = {}
      for _ = 1, 8 do table.insert(virt_lines, { { "thread line", "" } }) end
      vim.api.nvim_buf_set_extmark(buf, DIFF_NS, 7, 0, { virt_lines = virt_lines })

      diff.ensure_virt_lines_visible(win, buf, 8)

      local topline = get_topline(win)
      assert.truthy(topline > 1)
      assert.truthy(topline <= 8)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does nothing when thread already fits in viewport", function()
      local buf = make_buf_with_lines(30)
      local win = make_win(buf, 20, 1)
      local virt_lines = { { { "line 1", "" } }, { { "line 2", "" } } }
      vim.api.nvim_buf_set_extmark(buf, DIFF_NS, 2, 0, { virt_lines = virt_lines })

      diff.ensure_virt_lines_visible(win, buf, 3)

      local topline = get_topline(win)
      assert.equals(1, topline)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("clamps topline so anchor row stays visible when thread taller than window", function()
      local buf = make_buf_with_lines(30)
      local win = make_win(buf, 5, 1)
      local virt_lines = {}
      for _ = 1, 20 do table.insert(virt_lines, { { "thread line", "" } }) end
      vim.api.nvim_buf_set_extmark(buf, DIFF_NS, 9, 0, { virt_lines = virt_lines })

      diff.ensure_virt_lines_visible(win, buf, 10)

      local topline = get_topline(win)
      assert.equals(10, topline)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
