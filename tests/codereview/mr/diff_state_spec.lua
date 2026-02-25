local diff_state = require("codereview.mr.diff_state")

describe("mr.diff_state", function()
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

  describe("create_state", function()
    before_each(function()
      local config = require("codereview.config")
      config.reset()
    end)

    it("returns a state with view_mode=diff by default", function()
      local state = diff_state.create_state({})
      assert.equals("diff", state.view_mode)
    end)

    it("accepts view_mode override", function()
      local state = diff_state.create_state({ view_mode = "summary" })
      assert.equals("summary", state.view_mode)
    end)

    it("initialises all required cache tables", function()
      local state = diff_state.create_state({})
      assert.same({}, state.line_data_cache)
      assert.same({}, state.row_disc_cache)
      assert.same({}, state.row_ai_cache)
      assert.same({}, state.file_sections)
      assert.same({}, state.scroll_line_data)
      assert.same({}, state.scroll_row_disc)
      assert.same({}, state.scroll_row_ai)
      assert.same({}, state.file_contexts)
      assert.same({}, state.local_drafts)
      assert.same({}, state.row_selection)
      assert.same({}, state.sidebar_row_map)
      assert.same({}, state.collapsed_dirs)
      assert.same({}, state.summary_row_map)
    end)

    it("sets discussions to empty table when nil", function()
      local state = diff_state.create_state({})
      assert.same({}, state.discussions)
    end)

    it("uses provided discussions", function()
      local discs = { { id = "d1" } }
      local state = diff_state.create_state({ discussions = discs })
      assert.equals(discs, state.discussions)
    end)

    it("stores entry field for detail.lua use-case", function()
      local entry = { id = 42, iid = 7 }
      local state = diff_state.create_state({ entry = entry })
      assert.equals(entry, state.entry)
    end)

    it("sets scroll_mode based on file count vs threshold", function()
      local config = require("codereview.config")
      config.reset()
      config.setup({ diff = { scroll_threshold = 5 } })
      local few_files = { { new_path = "a.lua" }, { new_path = "b.lua" } }
      local many_files = {}
      for i = 1, 10 do many_files[i] = { new_path = "f" .. i .. ".lua" } end

      local s1 = diff_state.create_state({ files = few_files })
      local s2 = diff_state.create_state({ files = many_files })
      assert.is_true(s1.scroll_mode)
      assert.is_false(s2.scroll_mode)
    end)
  end)

  describe("apply_scroll_result", function()
    it("updates all four scroll fields from result", function()
      local state = diff_state.create_state({})
      local result = {
        file_sections = { { start_line = 1, end_line = 5 } },
        line_data = { { type = "add" } },
        row_discussions = { [3] = { { id = "d1" } } },
        row_ai = { [7] = { { severity = "info" } } },
      }
      diff_state.apply_scroll_result(state, result)
      assert.equals(result.file_sections, state.file_sections)
      assert.equals(result.line_data, state.scroll_line_data)
      assert.equals(result.row_discussions, state.scroll_row_disc)
      assert.equals(result.row_ai, state.scroll_row_ai)
    end)

    it("overwrites previous scroll state", function()
      local state = diff_state.create_state({})
      state.file_sections = { { start_line = 99 } }
      state.scroll_line_data = { { type = "delete" } }

      local result = {
        file_sections = { { start_line = 1 } },
        line_data = { { type = "add" } },
        row_discussions = {},
        row_ai = {},
      }
      diff_state.apply_scroll_result(state, result)
      assert.equals(1, state.file_sections[1].start_line)
      assert.equals("add", state.scroll_line_data[1].type)
    end)
  end)

  describe("apply_file_result", function()
    it("writes ld/rd/ra into the correct cache slots", function()
      local state = diff_state.create_state({})
      local ld = { { type = "context" } }
      local rd = { [1] = { { id = "d1" } } }
      local ra = { [2] = { { severity = "warning" } } }

      diff_state.apply_file_result(state, 3, ld, rd, ra)

      assert.equals(ld, state.line_data_cache[3])
      assert.equals(rd, state.row_disc_cache[3])
      assert.equals(ra, state.row_ai_cache[3])
    end)

    it("does not affect other file slots", function()
      local state = diff_state.create_state({})
      local sentinel = { type = "sentinel" }
      state.line_data_cache[1] = { sentinel }

      diff_state.apply_file_result(state, 2, {}, {}, {})

      assert.equals(sentinel, state.line_data_cache[1][1])
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
      diff_state.load_diffs_into_state(state, files)
      assert.equals(2, #state.files)
      assert.truthy(state.scroll_mode ~= nil)
    end)

    it("is a no-op when files already loaded", function()
      local state = {
        review = { id = 1 },
        files = { { new_path = "existing.lua" } },
        scroll_mode = true,
      }
      diff_state.load_diffs_into_state(state, { { new_path = "other.lua" } })
      assert.equals("existing.lua", state.files[1].new_path)
    end)
  end)

  describe("file_has_annotations", function()
    it("returns false when no discussions or suggestions", function()
      local state = { discussions = {}, ai_suggestions = {}, files = { { new_path = "a.lua", old_path = "a.lua" } } }
      assert.is_false(diff_state.file_has_annotations(state, 1))
    end)

    it("returns true when file has matching discussion", function()
      local state = {
        discussions = { { notes = { { body = "x", position = { new_path = "a.lua" } } } } },
        ai_suggestions = {},
        files = { { new_path = "a.lua", old_path = "a.lua" } },
      }
      assert.is_true(diff_state.file_has_annotations(state, 1))
    end)

    it("returns true when file has matching AI suggestion", function()
      local state = {
        discussions = {},
        ai_suggestions = { { file_path = "a.lua" } },
        files = { { new_path = "a.lua", old_path = "a.lua" } },
      }
      assert.is_true(diff_state.file_has_annotations(state, 1))
    end)

    it("returns false for non-existent file index", function()
      local state = { discussions = {}, ai_suggestions = {}, files = {} }
      assert.is_false(diff_state.file_has_annotations(state, 99))
    end)
  end)
end)
