local diff = require("codereview.mr.diff")

describe("mr.diff", function()
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

  describe("get_annotated_rows", function()
    it("returns empty for no annotations", function()
      assert.same({}, diff.get_annotated_rows({}, {}))
    end)

    it("merges and deduplicates comment + AI rows", function()
      local row_disc = { [3] = true, [7] = true }
      local row_ai = { [3] = true, [10] = true }
      assert.same({ 3, 7, 10 }, diff.get_annotated_rows(row_disc, row_ai))
    end)

    it("returns sorted rows from AI only", function()
      assert.same({ 2, 5 }, diff.get_annotated_rows({}, { [5] = true, [2] = true }))
    end)

    it("returns sorted rows from comments only", function()
      assert.same({ 1, 4 }, diff.get_annotated_rows({ [4] = true, [1] = true }, {}))
    end)
  end)

  describe("outdated comment remapping", function()
    local function make_line_data(new_lines)
      local ld = {}
      for _, nl in ipairs(new_lines) do
        table.insert(ld, { item = { new_line = nl, old_line = nl }, type = "context" })
      end
      return ld
    end

    local function make_buf(n)
      local buf = vim.api.nvim_create_buf(false, true)
      local lines = {}
      for i = 1, n do lines[i] = "line " .. i end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return buf
    end

    it("uses change_position line for GitLab outdated comment", function()
      local buf = make_buf(20)
      local line_data = make_line_data({ 10, 11, 12, 13, 14, 15, 16 })
      local review = { head_sha = "new_sha" }
      local discussions = {{
        id = "d1",
        notes = {{
          author = "alice",
          body = "outdated comment",
          created_at = "2026-01-01T00:00:00Z",
          position = {
            new_path = "a.lua",
            new_line = 10,
            head_sha = "old_sha",
          },
          change_position = {
            new_path = "a.lua",
            new_line = 15,
          },
        }},
      }}
      local file_diff = { new_path = "a.lua", old_path = "a.lua" }
      diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local found_row = nil
      for _, m in ipairs(marks) do
        if m[4] and m[4].virt_lines then
          found_row = m[2] + 1  -- 0-indexed to 1-indexed
        end
      end
      -- new_line=15 is the 6th entry in line_data
      assert.equals(6, found_row)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("skips outdated GitLab comment when change_position is nil", function()
      local buf = make_buf(20)
      local line_data = make_line_data({ 10, 11, 12 })
      local review = { head_sha = "new_sha" }
      local discussions = {{
        id = "d1",
        notes = {{
          author = "alice",
          body = "outdated comment",
          created_at = "2026-01-01T00:00:00Z",
          position = {
            new_path = "a.lua",
            new_line = 10,
            head_sha = "old_sha",
            -- no change_position
          },
        }},
      }}
      local file_diff = { new_path = "a.lua", old_path = "a.lua" }
      diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local has_virt_lines = false
      for _, m in ipairs(marks) do
        if m[4] and m[4].virt_lines then has_virt_lines = true end
      end
      assert.falsy(has_virt_lines, "Expected no virt_lines for outdated comment without change_position")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("places GitHub outdated comment using fallback originalLine", function()
      local buf = make_buf(25)
      local line_data = make_line_data({ 18, 19, 20, 21, 22 })
      local review = { head_sha = "new_sha" }
      local discussions = {{
        id = "d1",
        notes = {{
          author = "bob",
          body = "gh outdated",
          created_at = "2026-01-01T00:00:00Z",
          position = {
            new_path = "a.lua",
            new_line = 20,
            outdated = true,
          },
        }},
      }}
      local file_diff = { new_path = "a.lua", old_path = "a.lua" }
      diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local found_row = nil
      for _, m in ipairs(marks) do
        if m[4] and m[4].virt_lines then
          found_row = m[2] + 1
        end
      end
      -- new_line=20 is the 3rd entry in line_data
      assert.equals(3, found_row)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("places current-version comment normally", function()
      local buf = make_buf(20)
      local line_data = make_line_data({ 5, 6, 7, 8 })
      local review = { head_sha = "current_sha" }
      local discussions = {{
        id = "d1",
        notes = {{
          author = "carol",
          body = "normal comment",
          created_at = "2026-01-01T00:00:00Z",
          position = {
            new_path = "a.lua",
            new_line = 7,
            head_sha = "current_sha",
          },
        }},
      }}
      local file_diff = { new_path = "a.lua", old_path = "a.lua" }
      diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local found_row = nil
      for _, m in ipairs(marks) do
        if m[4] and m[4].virt_lines then
          found_row = m[2] + 1
        end
      end
      -- new_line=7 is the 3rd entry in line_data
      assert.equals(3, found_row)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("outdated badge appears in header for remapped GitLab comment", function()
      local buf = make_buf(20)
      local line_data = make_line_data({ 10, 11, 12, 13, 14, 15 })
      local review = { head_sha = "new_sha" }
      local discussions = {{
        id = "d1",
        notes = {{
          author = "alice",
          body = "outdated comment",
          created_at = "2026-01-01T00:00:00Z",
          position = {
            new_path = "a.lua",
            new_line = 10,
            head_sha = "old_sha",
          },
          change_position = {
            new_path = "a.lua",
            new_line = 15,
          },
        }},
      }}
      local file_diff = { new_path = "a.lua", old_path = "a.lua" }
      diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local found_outdated = false
      for _, m in ipairs(marks) do
        if m[4] and m[4].virt_lines then
          for _, vl in ipairs(m[4].virt_lines) do
            for _, chunk in ipairs(vl) do
              if chunk[1] and chunk[1]:find("Outdated") then
                found_outdated = true
              end
            end
          end
        end
      end
      assert.truthy(found_outdated, "Expected 'Outdated' badge in virt_lines header")
      vim.api.nvim_buf_delete(buf, { force = true })
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
