local diff_render = require("codereview.mr.diff_render")

describe("mr.diff_render", function()
  -- ─── Lookup map builders ─────────────────────────────────────────────────────

  describe("build_line_to_row", function()
    it("maps new_line to its row", function()
      local line_data = {
        { type = "context", item = { new_line = 1, old_line = 1 } },
        { type = "add",     item = { new_line = 2 } },
        { type = "context", item = { new_line = 3, old_line = 2 } },
      }
      local m = diff_render.build_line_to_row(line_data)
      assert.equals(1, m[1])
      assert.equals(2, m[2])
      assert.equals(3, m[3])
    end)

    it("maps old_line to row when no new_line", function()
      local line_data = {
        { type = "context", item = { new_line = 1, old_line = 1 } },
        { type = "delete",  item = { old_line = 2 } },
        { type = "add",     item = { new_line = 3 } },
      }
      local m = diff_render.build_line_to_row(line_data)
      assert.equals(1, m[1])
      assert.equals(2, m[2])  -- delete row: old_line=2
      assert.equals(3, m[3])  -- add row: new_line=3
    end)

    it("new_line takes priority when same number exists as old_line", function()
      -- delete old_line=5, then add new_line=5 — new_line wins
      local line_data = {
        { type = "delete",  item = { old_line = 5 } },
        { type = "add",     item = { new_line = 5 } },
      }
      local m = diff_render.build_line_to_row(line_data)
      -- row 2 (add, new_line=5) should win over row 1 (delete, old_line=5)
      assert.equals(2, m[5])
    end)

    it("skips entries with no item", function()
      local line_data = {
        { type = "file_header" },
        { type = "add", item = { new_line = 10 } },
      }
      local m = diff_render.build_line_to_row(line_data)
      assert.is_nil(m[nil])
      assert.equals(2, m[10])
    end)

    it("returns empty map for empty line_data", function()
      local m = diff_render.build_line_to_row({})
      assert.same({}, m)
    end)
  end)

  describe("build_line_to_row_scroll", function()
    it("maps file_idx:new_line to row", function()
      local all_line_data = {
        { type = "file_header", file_idx = 1 },
        { type = "context", item = { new_line = 1, old_line = 1 }, file_idx = 1 },
        { type = "add",     item = { new_line = 2 },               file_idx = 1 },
        { type = "file_header", file_idx = 2 },
        { type = "context", item = { new_line = 1, old_line = 1 }, file_idx = 2 },
      }
      local m = diff_render.build_line_to_row_scroll(all_line_data)
      assert.equals(2, m["1:1"])
      assert.equals(3, m["1:2"])
      assert.equals(5, m["2:1"])
    end)

    it("maps file_idx:old_line for delete-only rows", function()
      local all_line_data = {
        { type = "delete", item = { old_line = 7 }, file_idx = 1 },
        { type = "add",    item = { new_line = 7 }, file_idx = 1 },
      }
      local m = diff_render.build_line_to_row_scroll(all_line_data)
      -- new_line=7 wins for key "1:7"
      assert.equals(2, m["1:7"])
    end)

    it("separates same line numbers across files", function()
      local all_line_data = {
        { type = "add", item = { new_line = 5 }, file_idx = 1 },
        { type = "add", item = { new_line = 5 }, file_idx = 2 },
      }
      local m = diff_render.build_line_to_row_scroll(all_line_data)
      assert.equals(1, m["1:5"])
      assert.equals(2, m["2:5"])
    end)

    it("returns empty map for empty input", function()
      local m = diff_render.build_line_to_row_scroll({})
      assert.same({}, m)
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

  describe("render_file_diff diff_cache", function()
    it("populates cache on first call", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local file_diff = {
        new_path = "foo.lua", old_path = "foo.lua",
        diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n",
      }
      local review = {}
      local diff_cache = {}

      diff_render.render_file_diff(buf, file_diff, review, {}, 8, nil, nil, nil, nil, diff_cache)

      local key = "foo.lua:8"
      assert.truthy(diff_cache[key], "cache entry should exist after first call")
      assert.truthy(diff_cache[key].hunks, "cache should contain hunks")
      assert.truthy(diff_cache[key].display, "cache should contain display")

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("returns same line_data shape on second call (cache hit)", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local file_diff = {
        new_path = "bar.lua", old_path = "bar.lua",
        diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n",
      }
      local review = {}
      local diff_cache = {}

      local ld1 = diff_render.render_file_diff(buf, file_diff, review, {}, 8, nil, nil, nil, nil, diff_cache)
      local ld2 = diff_render.render_file_diff(buf, file_diff, review, {}, 8, nil, nil, nil, nil, diff_cache)

      assert.equals(#ld1, #ld2)
      for i = 1, #ld1 do
        assert.equals(ld1[i].type, ld2[i].type)
      end

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("uses different cache keys for different contexts", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local file_diff = {
        new_path = "baz.lua", old_path = "baz.lua",
        diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n",
      }
      local review = {}
      local diff_cache = {}

      diff_render.render_file_diff(buf, file_diff, review, {}, 3, nil, nil, nil, nil, diff_cache)
      diff_render.render_file_diff(buf, file_diff, review, {}, 8, nil, nil, nil, nil, diff_cache)

      assert.truthy(diff_cache["baz.lua:3"], "cache entry for context 3 should exist")
      assert.truthy(diff_cache["baz.lua:8"], "cache entry for context 8 should exist")

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does not error when diff_cache is nil", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local file_diff = {
        new_path = "no_cache.lua", old_path = "no_cache.lua",
        diff = "@@ -1,1 +1,1 @@\n-old\n+new\n",
      }
      local review = {}
      local ld = diff_render.render_file_diff(buf, file_diff, review, {}, 8)
      assert.truthy(#ld > 0)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("render_all_files diff_cache", function()
    it("populates cache on first call with per-file entries", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "foo.lua", old_path = "foo.lua", diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n" },
        { new_path = "bar.lua", old_path = "bar.lua", diff = "@@ -1,1 +1,1 @@\n-x\n+y\n" },
      }
      local review = {}
      local diff_cache = {}

      diff_render.render_all_files(buf, files, review, {}, 8, nil, nil, nil, nil, nil, diff_cache)

      assert.truthy(diff_cache["foo.lua:8"], "cache entry for foo.lua should exist")
      assert.truthy(diff_cache["foo.lua:8"].hunks, "cache should contain hunks")
      assert.truthy(diff_cache["foo.lua:8"].display, "cache should contain display")
      assert.truthy(diff_cache["bar.lua:8"], "cache entry for bar.lua should exist")

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("uses cache on second call (no git re-run)", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "cached.lua", old_path = "cached.lua", diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n" },
      }
      local review = {}
      local diff_cache = {}

      local r1 = diff_render.render_all_files(buf, files, review, {}, 8, nil, nil, nil, nil, nil, diff_cache)
      -- Poison the diff to verify the second call uses cache
      diff_cache["cached.lua:8"].sentinel = true
      local r2 = diff_render.render_all_files(buf, files, review, {}, 8, nil, nil, nil, nil, nil, diff_cache)

      assert.truthy(diff_cache["cached.lua:8"].sentinel, "cache should have been reused (sentinel preserved)")
      assert.equals(#r1.line_data, #r2.line_data)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("uses per-file context as cache key suffix", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "ctx.lua", old_path = "ctx.lua", diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n" },
      }
      local review = {}
      local diff_cache = {}

      -- file_contexts overrides global context for file 1
      diff_render.render_all_files(buf, files, review, {}, 8, { [1] = 3 }, nil, nil, nil, nil, diff_cache)

      assert.truthy(diff_cache["ctx.lua:3"], "cache key should use per-file context")
      assert.is_nil(diff_cache["ctx.lua:8"], "global context key should not exist")

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does not error when diff_cache is nil", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local files = {
        { new_path = "nocache.lua", old_path = "nocache.lua", diff = "@@ -1,1 +1,1 @@\n-a\n+b\n" },
      }
      local result = diff_render.render_all_files(buf, files, {}, {}, 8)
      assert.equals(1, #result.file_sections)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("update_selection_at_row", function()
    it("clears AIDRAFT_NS extmarks on target row only", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local aidraft_ns = vim.api.nvim_create_namespace("codereview_ai_draft")
      local diff_ns = vim.api.nvim_create_namespace("codereview_diff")

      -- Place extmarks on rows 2 (target) and 4 (other)
      vim.api.nvim_buf_set_extmark(buf, aidraft_ns, 1, 0, { virt_lines = { { { "AI", "hl" } } } })  -- row=2, 0-indexed=1
      vim.api.nvim_buf_set_extmark(buf, aidraft_ns, 3, 0, { virt_lines = { { { "AI2", "hl" } } } }) -- row=4, 0-indexed=3

      -- Also place a virt_lines extmark on target row in DIFF_NS
      vim.api.nvim_buf_set_extmark(buf, diff_ns, 1, 0, { virt_lines = { { { "comment", "hl" } } } })
      -- And a line_hl extmark on target row in DIFF_NS (should NOT be deleted)
      vim.api.nvim_buf_set_extmark(buf, diff_ns, 1, 0, { line_hl_group = "CodeReviewDiffAdd" })

      diff_render.update_selection_at_row(buf, 2, {}, {}, {}, nil, {}, nil)

      -- AIDRAFT_NS: target row (row=2, 0-indexed=1) should be cleared
      local ai_marks_target = vim.api.nvim_buf_get_extmarks(buf, aidraft_ns, { 1, 0 }, { 1, -1 }, {})
      assert.equals(0, #ai_marks_target, "AIDRAFT_NS extmarks on target row should be cleared")

      -- AIDRAFT_NS: other row (row=4, 0-indexed=3) should remain
      local ai_marks_other = vim.api.nvim_buf_get_extmarks(buf, aidraft_ns, { 3, 0 }, { 3, -1 }, {})
      assert.equals(1, #ai_marks_other, "AIDRAFT_NS extmarks on other row should remain")

      -- DIFF_NS: virt_lines extmark should be cleared
      local diff_marks = vim.api.nvim_buf_get_extmarks(buf, diff_ns, { 1, 0 }, { 1, -1 }, { details = true })
      for _, m in ipairs(diff_marks) do
        assert.is_nil(m[4].virt_lines, "DIFF_NS virt_lines extmark on target row should be cleared")
      end

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("re-renders AI suggestions on target row when row_ai provided", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1", "line2", "line3" })
      local aidraft_ns = vim.api.nvim_create_namespace("codereview_ai_draft")

      local row_ai = {
        [2] = { { severity = "info", comment = "fix this", status = "pending" } },
      }

      diff_render.update_selection_at_row(buf, 2, {}, row_ai, {}, nil, {}, nil)

      local ai_marks = vim.api.nvim_buf_get_extmarks(buf, aidraft_ns, { 1, 0 }, { 1, -1 }, { details = true })
      local has_virt_lines = false
      for _, m in ipairs(ai_marks) do
        if m[4] and m[4].virt_lines then has_virt_lines = true end
      end
      assert.truthy(has_virt_lines, "AI suggestion should be re-rendered as virt_lines")

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does not touch extmarks on other rows", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local aidraft_ns = vim.api.nvim_create_namespace("codereview_ai_draft")

      -- Place extmarks only on row 5 (0-indexed=4)
      local id = vim.api.nvim_buf_set_extmark(buf, aidraft_ns, 4, 0, { virt_lines = { { { "other", "hl" } } } })

      -- Update row 2 — should not touch row 5
      diff_render.update_selection_at_row(buf, 2, {}, {}, {}, nil, {}, nil)

      local other_marks = vim.api.nvim_buf_get_extmarks(buf, aidraft_ns, { 4, 0 }, { 4, -1 }, {})
      assert.equals(1, #other_marks, "extmarks on non-target rows should be untouched")
      assert.equals(id, other_marks[1][1], "mark ID should be unchanged")

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
