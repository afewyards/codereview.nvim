local diff_comments = require("codereview.mr.diff_comments")
local diff_render = require("codereview.mr.diff_render")

describe("mr.diff_comments", function()
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
      diff_render.place_comment_signs(buf, line_data, discussions, file_diff)
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
      diff_render.place_comment_signs(buf, line_data, discussions, file_diff)
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
      assert.same({}, diff_comments.build_row_items({}, {}))
    end)

    it("returns AI items first", function()
      local ai = { { severity = "info" }, { severity = "error" } }
      local result = diff_comments.build_row_items(ai, {})
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
      local result = diff_comments.build_row_items(ai, discs)
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
      local result = diff_comments.build_row_items({}, discs)
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
      assert.same({ type = "ai", index = 1 }, diff_comments.cycle_row_selection(items, nil, 1))
    end)

    it("cycles forward through items", function()
      assert.same(items[2], diff_comments.cycle_row_selection(items, items[1], 1))
      assert.same(items[3], diff_comments.cycle_row_selection(items, items[2], 1))
    end)

    it("returns nil past last item", function()
      assert.is_nil(diff_comments.cycle_row_selection(items, items[3], 1))
    end)

    it("nil -> last item backward", function()
      assert.same(items[3], diff_comments.cycle_row_selection(items, nil, -1))
    end)

    it("cycles backward", function()
      assert.same(items[2], diff_comments.cycle_row_selection(items, items[3], -1))
      assert.same(items[1], diff_comments.cycle_row_selection(items, items[2], -1))
    end)

    it("returns nil past first item backward", function()
      assert.is_nil(diff_comments.cycle_row_selection(items, items[1], -1))
    end)

    it("returns nil for empty items", function()
      assert.is_nil(diff_comments.cycle_row_selection({}, nil, 1))
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
      diff_render.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
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
      diff_render.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
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
      diff_render.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
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
      diff_render.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
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
      diff_render.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
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

end)
