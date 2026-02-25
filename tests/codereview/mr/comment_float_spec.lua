local comment_float = require("codereview.mr.comment_float")

describe("mr.comment_float", function()
  describe("inline float self-healing", function()
    local orig_win_get_buf
    local orig_buf_attach
    local orig_buf_set_extmark
    local orig_win_get_width
    local orig_open_win_sh
    local attached_callbacks
    local extmark_calls

    before_each(function()
      attached_callbacks = {}
      extmark_calls = {}

      package.loaded["codereview.config"] = {
        get = function() return { diff = { comment_width = 60 } } end,
      }

      -- Make diff_buf (99) distinguishable from popup buf
      orig_win_get_buf = vim.api.nvim_win_get_buf
      vim.api.nvim_win_get_buf = function() return 99 end

      -- Capture nvim_buf_attach callbacks per buf
      orig_buf_attach = vim.api.nvim_buf_attach
      vim.api.nvim_buf_attach = function(buf, send_buffer, callbacks)
        attached_callbacks[buf] = callbacks
        return true
      end

      -- Track extmark set calls; don't call orig since diff_buf (99) is not a real buf
      orig_buf_set_extmark = vim.api.nvim_buf_set_extmark
      vim.api.nvim_buf_set_extmark = function(buf, ns, row, col, opts)
        table.insert(extmark_calls, { buf = buf, row = row, opts = opts })
        return 1
      end

      -- Ensure use_inline is true (win_get_width >= 40) and nvim_open_win succeeds
      orig_win_get_width = vim.api.nvim_win_get_width
      vim.api.nvim_win_get_width = function() return 80 end

      orig_open_win_sh = vim.api.nvim_open_win
      vim.api.nvim_open_win = function(buf, _, _)
        return orig_open_win_sh(buf, false, {
          relative = "editor", width = 60, height = 3, row = 1, col = 1,
        })
      end
    end)

    after_each(function()
      vim.api.nvim_win_get_buf = orig_win_get_buf
      vim.api.nvim_buf_attach = orig_buf_attach
      vim.api.nvim_buf_set_extmark = orig_buf_set_extmark
      vim.api.nvim_win_get_width = orig_win_get_width
      vim.api.nvim_open_win = orig_open_win_sh
      package.loaded["codereview.config"] = nil
    end)

    local function open_inline_float()
      return comment_float.open("Test", {
        anchor_line = 5,
        win_id = vim.api.nvim_get_current_win(),
      })
    end

    it("re-reserves space when diff buffer is modified", function()
      open_inline_float()

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
      open_inline_float()

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
    local orig_win_get_width
    local orig_buf_set_extmark_ov
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

      -- Ensure use_inline is true and extmark calls on diff_buf (99) don't crash
      orig_win_get_width = vim.api.nvim_win_get_width
      vim.api.nvim_win_get_width = function() return 80 end

      orig_buf_set_extmark_ov = vim.api.nvim_buf_set_extmark
      vim.api.nvim_buf_set_extmark = function(buf, ns, row, col, opts)
        return 1
      end
    end)

    after_each(function()
      vim.api.nvim_win_get_buf = orig_win_get_buf
      vim.api.nvim_buf_attach = orig_buf_attach
      vim.api.nvim_open_win = orig_open_win
      vim.api.nvim_win_get_width = orig_win_get_width
      vim.api.nvim_buf_set_extmark = orig_buf_set_extmark_ov
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

      comment_float.open("Edit", {
        anchor_line = 5,
        win_id = vim.api.nvim_get_current_win(),
        spacer_offset = 2,
      })

      ifloat.reserve_space = orig_reserve
      assert.is_false(reserve_space_called)
    end)

    it("skips self-heal buf_attach on diff_buf when spacer_offset is set", function()
      comment_float.open("Edit", {
        anchor_line = 5,
        win_id = vim.api.nvim_get_current_win(),
        spacer_offset = 2,
      })
      assert.equals(0, #attached_diff_bufs)
    end)

    it("uses spacer_offset + 1 as float row when spacer_offset is set", function()
      comment_float.open("Edit", {
        anchor_line = 5,
        win_id = vim.api.nvim_get_current_win(),
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

      comment_float.open("Comment", {
        anchor_line = 5,
        win_id = vim.api.nvim_get_current_win(),
      })

      ifloat.reserve_space = orig_reserve
      assert.is_true(reserve_space_called)
      assert.equals(1, #attached_diff_bufs)
    end)
  end)

  describe("dynamic resize", function()
    local orig_timer_start
    local orig_buf_attach
    local orig_win_get_buf
    local orig_win_get_width
    local orig_open_win_dr
    local orig_buf_is_valid
    local orig_buf_set_extmark_dr
    local buf_callbacks

    before_each(function()
      buf_callbacks = {}

      package.loaded["codereview.config"] = {
        get = function() return { diff = { comment_width = 60 } } end,
      }

      orig_win_get_buf = vim.api.nvim_win_get_buf
      vim.api.nvim_win_get_buf = function() return 99 end

      -- Capture all buf_attach callbacks
      orig_buf_attach = vim.api.nvim_buf_attach
      vim.api.nvim_buf_attach = function(buf, _, callbacks)
        buf_callbacks[buf] = callbacks
        return true
      end

      -- Run timer callbacks immediately (no 15ms delay)
      orig_timer_start = vim.fn.timer_start
      vim.fn.timer_start = function(_, cb)
        cb()
        return 0
      end

      -- Ensure use_inline is true; open a real editor-relative window so win is valid
      orig_win_get_width = vim.api.nvim_win_get_width
      vim.api.nvim_win_get_width = function() return 80 end

      orig_open_win_dr = vim.api.nvim_open_win
      vim.api.nvim_open_win = function(buf, _, _)
        return orig_open_win_dr(buf, false, {
          relative = "editor", width = 60, height = 3, row = 1, col = 1,
        })
      end

      -- Allow buf_is_valid(99) so the elseif branch in the resize handler can fire
      orig_buf_is_valid = vim.api.nvim_buf_is_valid
      vim.api.nvim_buf_is_valid = function(b)
        if b == 99 then return true end
        return orig_buf_is_valid(b)
      end

      -- Don't call orig buf_set_extmark since diff_buf (99) is not a real buf
      orig_buf_set_extmark_dr = vim.api.nvim_buf_set_extmark
      vim.api.nvim_buf_set_extmark = function(buf, ns, row, col, opts)
        return 1
      end
    end)

    after_each(function()
      vim.fn.timer_start = orig_timer_start
      vim.api.nvim_buf_attach = orig_buf_attach
      vim.api.nvim_win_get_buf = orig_win_get_buf
      vim.api.nvim_win_get_width = orig_win_get_width
      vim.api.nvim_open_win = orig_open_win_dr
      vim.api.nvim_buf_is_valid = orig_buf_is_valid
      vim.api.nvim_buf_set_extmark = orig_buf_set_extmark_dr
      package.loaded["codereview.config"] = nil
    end)

    local function popup_buf_from_callbacks()
      for b, _ in pairs(buf_callbacks) do
        if b ~= 99 then return b end
      end
    end

    it("calls on_resize(new_height) and skips update_space in overlay mode", function()
      local on_resize_called_with = nil
      local update_space_called = false
      local ifloat = require("codereview.ui.inline_float")
      local orig_update = ifloat.update_space
      ifloat.update_space = function() update_space_called = true end

      comment_float.open("Edit", {
        anchor_line = 5,
        win_id = vim.api.nvim_get_current_win(),
        spacer_offset = 2,
        on_resize = function(h) on_resize_called_with = h end,
      })

      local popup_buf = popup_buf_from_callbacks()
      if popup_buf and buf_callbacks[popup_buf] then
        buf_callbacks[popup_buf].on_lines()
      end

      ifloat.update_space = orig_update

      assert.is_not_nil(on_resize_called_with, "on_resize should have been called")
      assert.is_false(update_space_called)
    end)

    it("calls update_space and skips on_resize in normal mode", function()
      local on_resize_called = false
      local update_space_called = false
      local ifloat = require("codereview.ui.inline_float")
      local orig_update = ifloat.update_space
      local orig_reserve = ifloat.reserve_space
      ifloat.update_space = function() update_space_called = true end
      ifloat.reserve_space = function() return 42 end  -- return valid extmark_id

      comment_float.open("Comment", {
        anchor_line = 5,
        win_id = vim.api.nvim_get_current_win(),
        on_resize = function() on_resize_called = true end,
      })

      local popup_buf = popup_buf_from_callbacks()
      if popup_buf and buf_callbacks[popup_buf] then
        buf_callbacks[popup_buf].on_lines()
      end

      ifloat.update_space = orig_update
      ifloat.reserve_space = orig_reserve

      assert.is_true(update_space_called)
      assert.is_false(on_resize_called)
    end)

    it("overlay mode without on_resize does not crash", function()
      comment_float.open("Edit", {
        anchor_line = 5,
        win_id = vim.api.nvim_get_current_win(),
        spacer_offset = 1,
        -- no on_resize
      })

      local popup_buf = popup_buf_from_callbacks()
      if popup_buf and buf_callbacks[popup_buf] then
        buf_callbacks[popup_buf].on_lines()
      end
      -- Should not crash
      assert.is_true(true)
    end)
  end)
end)
