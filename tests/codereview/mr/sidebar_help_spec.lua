describe("mr.sidebar_help", function()
  local sidebar_help

  before_each(function()
    package.loaded["codereview.mr.sidebar_help"] = nil
    package.loaded["codereview.keymaps"] = {
      get = function(action)
        local bindings = {
          next_file            = "]f",
          prev_file            = "[f",
          toggle_full_file     = "<C-f>",
          toggle_scroll_mode   = "<C-a>",
          create_comment       = "cc",
          create_range_comment = "cc",
          reply                = "r",
          toggle_resolve       = "gt",
          accept_suggestion    = "a",
          dismiss_suggestion   = "x",
          submit               = "S",
          approve              = "a",
          open_in_browser      = "o",
          ai_review            = "A",
          refresh              = "R",
          quit                 = "Q",
          pick_files           = "<leader>ff",
        }
        return bindings[action]
      end,
    }
    sidebar_help = require("codereview.mr.sidebar_help")
  end)

  after_each(function()
    package.loaded["codereview.mr.sidebar_help"] = nil
    package.loaded["codereview.keymaps"] = nil
  end)

  -- ── build_lines() ─────────────────────────────────────────────────────────

  describe("build_lines()", function()
    it("returns a non-empty array of strings", function()
      local lines = sidebar_help.build_lines()
      assert.is_table(lines)
      assert.truthy(#lines > 0)
      for _, l in ipairs(lines) do
        assert.is_string(l)
      end
    end)

    it("contains Navigation section header", function()
      local lines = sidebar_help.build_lines()
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Navigation"), "expected 'Navigation' in help lines")
    end)

    it("contains Review section header", function()
      local lines = sidebar_help.build_lines()
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Review"), "expected 'Review' in help lines")
    end)

    it("contains General section header", function()
      local lines = sidebar_help.build_lines()
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("General"), "expected 'General' in help lines")
    end)

    it("converts <C-f> to ⌃F", function()
      local lines = sidebar_help.build_lines()
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("⌃F", 1, true), "expected ⌃F (Ctrl-F) in help lines")
    end)

    it("converts <C-a> to ⌃A", function()
      local lines = sidebar_help.build_lines()
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("⌃A", 1, true), "expected ⌃A (Ctrl-A) in help lines")
    end)

    it("includes action descriptions", function()
      local lines = sidebar_help.build_lines()
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Next file"),  "expected 'Next file' description")
      assert.truthy(joined:find("Quit"),        "expected 'Quit' description")
      assert.truthy(joined:find("New comment"), "expected 'New comment' description")
    end)

    it("shows plain keys without angle brackets", function()
      local lines = sidebar_help.build_lines()
      local joined = table.concat(lines, "\n")
      -- "]f" and "[f" should appear without mangling
      assert.truthy(joined:find("]f", 1, true), "expected plain ]f key")
    end)

    it("shows (disabled) for nil keys", function()
      package.loaded["codereview.keymaps"] = {
        get = function() return nil end,
      }
      package.loaded["codereview.mr.sidebar_help"] = nil
      local help = require("codereview.mr.sidebar_help")
      local lines = help.build_lines()
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("%(disabled%)"), "expected '(disabled)' for nil keys")
    end)
  end)

  -- ── open() ────────────────────────────────────────────────────────────────

  describe("open()", function()
    local orig_open_win
    local captured_cfg

    before_each(function()
      orig_open_win = vim.api.nvim_open_win
      vim.api.nvim_open_win = function(buf, enter, cfg)
        captured_cfg = cfg
        -- use a real window but with minimal config so headless tests work
        return orig_open_win(buf, false, {
          relative = "editor", width = 60, height = 20, row = 1, col = 1,
          style = "minimal", border = "rounded",
        })
      end
    end)

    after_each(function()
      vim.api.nvim_open_win = orig_open_win
      captured_cfg = nil
    end)

    it("creates a valid buffer and window", function()
      local handle = sidebar_help.open()
      assert.truthy(vim.api.nvim_buf_is_valid(handle.buf), "buf should be valid")
      assert.truthy(vim.api.nvim_win_is_valid(handle.win), "win should be valid")
      vim.api.nvim_win_close(handle.win, true)
    end)

    it("opens with relative='editor'", function()
      local handle = sidebar_help.open()
      assert.equals("editor", captured_cfg.relative)
      vim.api.nvim_win_close(handle.win, true)
    end)

    it("opens with border='rounded'", function()
      local handle = sidebar_help.open()
      assert.equals("rounded", captured_cfg.border)
      vim.api.nvim_win_close(handle.win, true)
    end)

    it("buffer contains help content", function()
      local handle = sidebar_help.open()
      local lines = vim.api.nvim_buf_get_lines(handle.buf, 0, -1, false)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Navigation"), "expected Navigation section in buffer")
      vim.api.nvim_win_close(handle.win, true)
    end)

    it("maps q to close", function()
      local handle = sidebar_help.open()
      local keymaps = vim.api.nvim_buf_get_keymap(handle.buf, "n")
      local has_q = false
      for _, km in ipairs(keymaps) do
        if km.lhs == "q" then has_q = true; break end
      end
      assert.is_true(has_q, "expected 'q' keymap to close the float")
      vim.api.nvim_win_close(handle.win, true)
    end)

    it("maps <Esc> to close", function()
      local handle = sidebar_help.open()
      local keymaps = vim.api.nvim_buf_get_keymap(handle.buf, "n")
      local has_esc = false
      for _, km in ipairs(keymaps) do
        if km.lhs == "<Esc>" then has_esc = true; break end
      end
      assert.is_true(has_esc, "expected '<Esc>' keymap to close the float")
      vim.api.nvim_win_close(handle.win, true)
    end)
  end)
end)
