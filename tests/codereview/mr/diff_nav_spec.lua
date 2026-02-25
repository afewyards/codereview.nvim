local diff_nav = require("codereview.mr.diff_nav")

describe("mr.diff_nav", function()
  describe("find_anchor", function()
    it("extracts old_line/new_line from a diff line", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
        { type = "context", item = { old_line = 10, new_line = 10, text = "ctx" }, file_idx = 1 },
        { type = "delete", item = { old_line = 11, new_line = nil, text = "old" }, file_idx = 1 },
        { type = "add", item = { old_line = nil, new_line = 11, text = "new" }, file_idx = 1 },
      }
      local anchor = diff_nav.find_anchor(line_data, 2, 1)
      assert.equals(1, anchor.file_idx)
      assert.equals(10, anchor.old_line)
      assert.equals(10, anchor.new_line)
    end)

    it("returns file_idx only for non-diff lines", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
        { type = "add", item = { old_line = nil, new_line = 5, text = "x" }, file_idx = 1 },
      }
      local anchor = diff_nav.find_anchor(line_data, 1, 1)
      assert.equals(1, anchor.file_idx)
      assert.is_nil(anchor.old_line)
      assert.is_nil(anchor.new_line)
    end)

    it("uses explicit file_idx for per-file line_data (no file_idx field)", function()
      local line_data = {
        { type = "context", item = { old_line = 5, new_line = 5, text = "x" } },
      }
      local anchor = diff_nav.find_anchor(line_data, 1, 3)
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
      local row = diff_nav.find_row_for_anchor(line_data, { file_idx = 1, new_line = 11 })
      assert.equals(3, row)
    end)

    it("finds exact old_line match for delete-only anchor", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
        { type = "delete", item = { old_line = 20, new_line = nil }, file_idx = 1 },
        { type = "context", item = { old_line = 21, new_line = 20 }, file_idx = 1 },
      }
      local row = diff_nav.find_row_for_anchor(line_data, { file_idx = 1, old_line = 20, new_line = nil })
      assert.equals(2, row)
    end)

    it("falls back to closest new_line in same file", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
        { type = "context", item = { old_line = 5, new_line = 5 }, file_idx = 1 },
        { type = "context", item = { old_line = 50, new_line = 50 }, file_idx = 1 },
      }
      -- Anchor line 8 doesn't exist; line 5 is closer than line 50
      local row = diff_nav.find_row_for_anchor(line_data, { file_idx = 1, new_line = 8 })
      assert.equals(2, row)
    end)

    it("falls back to first diff line when anchor has no line numbers", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
        { type = "context", item = { old_line = 1, new_line = 1 }, file_idx = 1 },
        { type = "file_header", file_idx = 2 },
        { type = "context", item = { old_line = 1, new_line = 1 }, file_idx = 2 },
      }
      local row = diff_nav.find_row_for_anchor(line_data, { file_idx = 2 })
      assert.equals(4, row)
    end)

    it("returns 1 when nothing matches", function()
      local line_data = {
        { type = "file_header", file_idx = 1 },
      }
      local row = diff_nav.find_row_for_anchor(line_data, { file_idx = 5, new_line = 99 })
      assert.equals(1, row)
    end)

    it("matches correct file_idx in multi-file scroll data", function()
      local line_data = {
        { type = "context", item = { old_line = 10, new_line = 10 }, file_idx = 1 },
        { type = "context", item = { old_line = 10, new_line = 10 }, file_idx = 2 },
      }
      local row = diff_nav.find_row_for_anchor(line_data, { file_idx = 2, new_line = 10 })
      assert.equals(2, row)
    end)
  end)

  describe("get_annotated_rows", function()
    it("returns empty for no annotations", function()
      assert.same({}, diff_nav.get_annotated_rows({}, {}))
    end)

    it("merges and deduplicates comment + AI rows", function()
      local row_disc = { [3] = true, [7] = true }
      local row_ai = { [3] = true, [10] = true }
      assert.same({ 3, 7, 10 }, diff_nav.get_annotated_rows(row_disc, row_ai))
    end)

    it("returns sorted rows from AI only", function()
      assert.same({ 2, 5 }, diff_nav.get_annotated_rows({}, { [5] = true, [2] = true }))
    end)

    it("returns sorted rows from comments only", function()
      assert.same({ 1, 4 }, diff_nav.get_annotated_rows({ [4] = true, [1] = true }, {}))
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

      diff_nav.ensure_virt_lines_visible(win, buf, 8)

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

      diff_nav.ensure_virt_lines_visible(win, buf, 3)

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

      diff_nav.ensure_virt_lines_visible(win, buf, 10)

      local topline = get_topline(win)
      assert.equals(10, topline)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

end)
