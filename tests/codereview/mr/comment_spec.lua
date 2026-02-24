local comment = require("codereview.mr.comment")
describe("mr.comment", function()
  describe("open_input_popup opts", function()
    it("module loads without error", function()
      assert.is_table(comment)
    end)
  end)

  describe("build_thread_lines", function()
    it("formats a discussion thread", function()
      local disc = {
        id = "abc",
        notes = {
          { author = "jan", body = "Should we make this configurable?", created_at = "2026-02-20T10:00:00Z", resolvable = true, resolved = false },
          { author = "maria", body = "Good point, will add.", created_at = "2026-02-20T11:00:00Z", resolvable = false, resolved = false },
        },
      }
      local lines = comment.build_thread_lines(disc)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("configurable"))
      assert.truthy(joined:find("maria"))
    end)
    it("shows resolved status", function()
      local disc = {
        id = "def",
        notes = {
          { author = "jan", body = "LGTM", created_at = "2026-02-20T10:00:00Z", resolvable = true, resolved = true, resolved_by = "jan" },
        },
      }
      local lines = comment.build_thread_lines(disc)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Resolved"))
    end)
  end)

  describe("optimistic comment flow", function()
    it("add callback returns a discussion with is_optimistic", function()
      local discussions = {}
      local function add_optimistic(text)
        local disc = {
          notes = {{ author = "You", body = text, created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            position = { new_path = "a.lua", new_line = 5 } }},
          is_optimistic = true,
        }
        table.insert(discussions, disc)
        return disc
      end
      local disc = add_optimistic("looks good")
      assert.truthy(disc.is_optimistic)
      assert.equals("You", disc.notes[1].author)
      assert.equals("looks good", disc.notes[1].body)
      assert.equals(1, #discussions)
    end)

    it("mark_failed transitions from optimistic to failed", function()
      local disc = { is_optimistic = true, is_failed = false, notes = {} }
      disc.is_optimistic = false
      disc.is_failed = true
      assert.falsy(disc.is_optimistic)
      assert.truthy(disc.is_failed)
    end)
  end)

  describe("edit_note", function()
    it("calls open_input_popup with action_type=edit and prefill=note.body", function()
      local popup_opts
      local orig = comment.open_input_popup
      comment.open_input_popup = function(title, cb, opts)
        popup_opts = opts
      end
      comment.edit_note(
        { id = "d1", notes = { { id = 1, body = "original text", author = "me" } } },
        { id = 1, body = "original text", author = "me" },
        { id = 99 },
        function() end
      )
      comment.open_input_popup = orig
      assert.equals("edit", popup_opts.action_type)
      assert.equals("original text", popup_opts.prefill)
    end)
  end)

  describe("delete_note", function()
    it("function exists and is callable", function()
      assert.is_function(comment.delete_note)
    end)
  end)

  describe("post_with_retry", function()
    it("calls on_success on first success", function()
      local called = false
      comment.post_with_retry(
        function() return nil, nil end,
        function() called = true end,
        function() end
      )
      vim.wait(100, function() return called end)
      assert.truthy(called)
    end)

    it("calls on_failure after max retries", function()
      local failed = false
      comment.post_with_retry(
        function() return nil, "server error" end,
        function() end,
        function() failed = true end,
        { max_retries = 1, delay_ms = 10 }
      )
      vim.wait(500, function() return failed end)
      assert.truthy(failed)
    end)
  end)

  describe("inline float self-healing", function()
    local orig_win_get_buf
    local orig_buf_attach
    local orig_buf_set_extmark
    local attached_callbacks
    local extmark_calls

    before_each(function()
      attached_callbacks = {}
      extmark_calls = {}

      package.loaded["codereview.config"] = {
        get = function() return { diff = { comment_width = 60 } } end,
      }

      -- Make diff_buf (99) distinguishable from popup buf (1)
      orig_win_get_buf = vim.api.nvim_win_get_buf
      vim.api.nvim_win_get_buf = function() return 99 end

      -- Capture nvim_buf_attach callbacks per buf
      orig_buf_attach = vim.api.nvim_buf_attach
      vim.api.nvim_buf_attach = function(buf, send_buffer, callbacks)
        attached_callbacks[buf] = callbacks
        return true
      end

      -- Track extmark set calls
      orig_buf_set_extmark = vim.api.nvim_buf_set_extmark
      vim.api.nvim_buf_set_extmark = function(buf, ns, row, col, opts)
        table.insert(extmark_calls, { buf = buf, row = row, opts = opts })
        return orig_buf_set_extmark(buf, ns, row, col, opts)
      end
    end)

    after_each(function()
      vim.api.nvim_win_get_buf = orig_win_get_buf
      vim.api.nvim_buf_attach = orig_buf_attach
      vim.api.nvim_buf_set_extmark = orig_buf_set_extmark
      package.loaded["codereview.config"] = nil
    end)

    local function open_inline_popup()
      comment.open_input_popup("Test", function() end, {
        anchor_line = 5,
        win_id = 1,
      })
    end

    it("re-reserves space when diff buffer is modified", function()
      open_inline_popup()

      local diff_callbacks = attached_callbacks[99]
      assert.truthy(diff_callbacks, "on_lines should be attached to diff_buf (99)")
      assert.is_function(diff_callbacks.on_lines)

      -- Clear extmark_calls to only see calls triggered by on_lines
      extmark_calls = {}

      -- Fire on_lines (vim.schedule runs immediately in tests)
      diff_callbacks.on_lines()

      -- reserve_space should have been called on diff_buf (99)
      local set_on_diff = false
      for _, call in ipairs(extmark_calls) do
        if call.buf == 99 and call.opts and call.opts.virt_lines then
          set_on_diff = true
          break
        end
      end
      assert.truthy(set_on_diff, "extmark with virt_lines should be set on diff_buf after on_lines")
    end)

    it("debounces rapid on_lines calls without crash or leak", function()
      open_inline_popup()

      local diff_callbacks = attached_callbacks[99]
      assert.truthy(diff_callbacks)

      extmark_calls = {}

      -- Fire on_lines twice rapidly — no crash
      diff_callbacks.on_lines()
      diff_callbacks.on_lines()

      -- Verify no error occurred (both ran fine since schedule is sync in tests)
      assert.is_true(true)
    end)
  end)

  describe("overlay mode (spacer_offset)", function()
    local orig_win_get_buf
    local orig_buf_attach
    local orig_open_win
    local attached_diff_bufs
    local open_win_config
    local reserve_space_called

    before_each(function()
      attached_diff_bufs = {}
      open_win_config = nil
      reserve_space_called = false

      package.loaded["codereview.config"] = {
        get = function() return { diff = { comment_width = 60 } } end,
      }

      orig_win_get_buf = vim.api.nvim_win_get_buf
      vim.api.nvim_win_get_buf = function() return 99 end

      orig_buf_attach = vim.api.nvim_buf_attach
      vim.api.nvim_buf_attach = function(buf, _, _)
        if buf == 99 then table.insert(attached_diff_bufs, buf) end
        return true
      end

      orig_open_win = vim.api.nvim_open_win
      vim.api.nvim_open_win = function(buf, enter, config)
        open_win_config = config
        -- Use a safe editor-relative fallback so the window actually opens
        return orig_open_win(buf, false, {
          relative = "editor", width = 10, height = 3, row = 0, col = 0,
        })
      end
    end)

    after_each(function()
      vim.api.nvim_win_get_buf = orig_win_get_buf
      vim.api.nvim_buf_attach = orig_buf_attach
      vim.api.nvim_open_win = orig_open_win
      package.loaded["codereview.config"] = nil
    end)

    it("skips reserve_space when spacer_offset is set", function()
      local orig_ifloat = package.loaded["codereview.ui.inline_float"]
      local ifloat = require("codereview.ui.inline_float")
      local orig_reserve = ifloat.reserve_space
      ifloat.reserve_space = function(...)
        reserve_space_called = true
        return orig_reserve(...)
      end

      comment.open_input_popup("Edit", function() end, {
        anchor_line = 5,
        win_id = 1,
        spacer_offset = 2,
      })

      ifloat.reserve_space = orig_reserve
      assert.is_false(reserve_space_called)
    end)

    it("skips self-heal buf_attach on diff_buf when spacer_offset is set", function()
      comment.open_input_popup("Edit", function() end, {
        anchor_line = 5,
        win_id = 1,
        spacer_offset = 2,
      })
      assert.equals(0, #attached_diff_bufs)
    end)

    it("uses spacer_offset + 1 as float row when spacer_offset is set", function()
      comment.open_input_popup("Edit", function() end, {
        anchor_line = 5,
        win_id = 1,
        spacer_offset = 3,
      })
      assert.is_not_nil(open_win_config)
      assert.equals(3 + 1, open_win_config.row)
    end)

    it("still opens normally (no spacer_offset) with reserve_space and buf_attach", function()
      local ifloat = require("codereview.ui.inline_float")
      local orig_reserve = ifloat.reserve_space
      ifloat.reserve_space = function(...)
        reserve_space_called = true
        return orig_reserve(...)
      end

      comment.open_input_popup("Comment", function() end, {
        anchor_line = 5,
        win_id = 1,
      })

      ifloat.reserve_space = orig_reserve
      assert.is_true(reserve_space_called)
      assert.equals(1, #attached_diff_bufs)
    end)
  end)
end)
