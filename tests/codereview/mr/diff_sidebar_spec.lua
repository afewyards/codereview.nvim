local diff_sidebar = require("codereview.mr.diff_sidebar")

describe("mr.diff_sidebar", function()
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
      diff_sidebar.render_summary(buf, state)

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
      diff_sidebar.render_summary(buf, state)
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
      diff_sidebar.render_sidebar(buf, state)
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
      diff_sidebar.render_sidebar(buf, state)
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
      diff_sidebar.render_sidebar(buf, state)
      for row, entry in pairs(state.sidebar_row_map) do
        if entry.type == "file" then
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          assert.truthy(lines[row]:match("^%s%s "))
        end
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
