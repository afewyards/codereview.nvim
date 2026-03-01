local merge_float = require("codereview.mr.merge_float")

describe("merge_float", function()
  describe("build_lines", function()
    it("builds gitlab lines with three checkboxes", function()
      local items = merge_float.build_items("gitlab")
      assert.equals(3, #items)
      assert.equals("checkbox", items[1].type)
      assert.equals("squash", items[1].key)
      assert.equals("checkbox", items[2].type)
      assert.equals("remove_source_branch", items[2].key)
      assert.equals("checkbox", items[3].type)
      assert.equals("auto_merge", items[3].key)
    end)

    it("builds github items with method cycle and one checkbox", function()
      local items = merge_float.build_items("github")
      assert.equals(2, #items)
      assert.equals("cycle", items[1].type)
      assert.equals("merge_method", items[1].key)
      assert.equals("checkbox", items[2].type)
      assert.equals("remove_source_branch", items[2].key)
    end)
  end)

  describe("render_line", function()
    it("renders unchecked checkbox", function()
      local item = { type = "checkbox", key = "squash", label = "Squash commits", checked = false }
      assert.equals("  [ ] Squash commits", merge_float.render_line(item))
    end)

    it("renders checked checkbox", function()
      local item = { type = "checkbox", key = "squash", label = "Squash commits", checked = true }
      assert.equals("  [x] Squash commits", merge_float.render_line(item))
    end)

    it("renders cycle item", function()
      local item = { type = "cycle", key = "merge_method", label = "Method", values = { "merge", "squash", "rebase" }, idx = 2 }
      assert.equals("  Method: ◀ squash ▶", merge_float.render_line(item))
    end)
  end)

  describe("collect_opts", function()
    it("collects checkbox states into opts table", function()
      local items = {
        { type = "checkbox", key = "squash", checked = true },
        { type = "checkbox", key = "remove_source_branch", checked = false },
        { type = "checkbox", key = "auto_merge", checked = true },
      }
      local opts = merge_float.collect_opts(items)
      assert.is_true(opts.squash)
      assert.is_nil(opts.remove_source_branch)
      assert.is_true(opts.auto_merge)
    end)

    it("collects cycle value into opts", function()
      local items = {
        { type = "cycle", key = "merge_method", values = { "merge", "squash", "rebase" }, idx = 2 },
        { type = "checkbox", key = "remove_source_branch", checked = true },
      }
      local opts = merge_float.collect_opts(items)
      assert.equals("squash", opts.merge_method)
      assert.is_true(opts.remove_source_branch)
    end)
  end)

  describe("open", function()
    it("creates a float window and buffer", function()
      local review = { id = 42 }
      local handle = merge_float.open(review, "gitlab")
      assert.is_true(vim.api.nvim_win_is_valid(handle.win))
      assert.is_true(vim.api.nvim_buf_is_valid(handle.buf))
      -- Verify buffer content
      local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)
      -- Should have: blank, 3 checkboxes, blank, button, blank = 7 lines
      assert.equals(7, #lines)
      assert.truthy(lines[2]:find("%[ %] Squash commits"))
      assert.truthy(lines[3]:find("%[ %] Delete source branch"))
      assert.truthy(lines[4]:find("%[ %] Merge when pipeline succeeds"))
      assert.truthy(lines[6]:find("%[ Merge %]"))
      handle.close()
    end)

    it("github float has method cycle and one checkbox", function()
      local handle = merge_float.open({ id = 10 }, "github")
      local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)
      -- blank, method cycle, checkbox, blank, button, blank = 6 lines
      assert.equals(6, #lines)
      assert.truthy(lines[2]:find("Method:"))
      assert.truthy(lines[3]:find("%[ %] Delete source branch"))
      handle.close()
    end)

    it("calls on_merge callback with collected opts on CR", function()
      pending("requires nvim_feedkeys — verify manually in Neovim")
    end)

    it("closes on q without calling merge", function()
      pending("requires nvim_feedkeys — verify manually in Neovim")
    end)
  end)
end)
