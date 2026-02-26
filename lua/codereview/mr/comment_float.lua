--- Float window management for comment input popups.
--- Returns a handle table: { buf, win, close, get_text }
local M = {}

--- Open a floating input window.
--- @param title string  Title shown in the border
--- @param opts? table  {
---   anchor_line?, win_id?, action_type?, context_text?, prefill?,
---   spacer_offset?, thread_height?, anchor_start?, is_reply?,
---   on_close?, on_resize?,
--- }
--- @return table handle  { buf, win, close, get_text, closed }
function M.open(title, opts)
  opts = opts or {}
  local ifloat = require("codereview.ui.inline_float")

  local header_count = 0

  -- Determine if we can use inline mode
  local use_inline = opts.anchor_line and opts.win_id
    and vim.api.nvim_win_is_valid(opts.win_id)
    and vim.api.nvim_win_get_width(opts.win_id) >= 40

  -- Buffer setup
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  -- Set initial content: prefill or empty line
  local init_lines = {}
  if opts.prefill and opts.prefill ~= "" then
    for _, pl in ipairs(vim.split(opts.prefill, "\n")) do
      table.insert(init_lines, pl)
    end
  else
    table.insert(init_lines, "")
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, init_lines)

  local content_count = #init_lines - header_count
  local total_height = ifloat.compute_height(content_count, header_count)

  local styled_title = ifloat.title(title)
  local styled_footer = ifloat.footer()

  -- Handle table — all shared state lives here so closures don't use dangling upvalues
  local handle = {
    buf = buf,
    win = nil,
    closed = false,
    extmark_id = nil,
    line_hl_ids = {},
    diff_buf = nil,
    reserve_line = nil,
    reserve_above = nil,
  }

  if use_inline then
    local anchor_0 = opts.anchor_line - 1  -- convert to 0-indexed
    handle.diff_buf = vim.api.nvim_win_get_buf(opts.win_id)

    -- Overlay mode: spacer_offset is set when editing an existing note inline.
    -- The spacer virt_lines are already rendered in the diff; skip reserve_space
    -- and self-heal since there is no separate reserved gap to maintain.
    local is_edit_overlay = type(opts.spacer_offset) == "number"

    -- Highlight the target line(s)
    local hl_start = opts.anchor_start or opts.anchor_line
    handle.line_hl_ids = ifloat.highlight_lines(handle.diff_buf, hl_start, opts.anchor_line)
    local cfg = require("codereview.config").get()
    local win_width = vim.api.nvim_win_get_width(opts.win_id)
    local max_w = cfg.diff.comment_width + 8  -- match rendered comment width + border/padding
    local width = math.min(win_width - 4, max_w)

    if not is_edit_overlay then
      -- Reserve space: when replying to a thread, place the gap on the next
      -- buffer line (above it) so it appears after the comment's virt_lines.
      handle.reserve_line = anchor_0
      handle.reserve_above = false
      if opts.thread_height and opts.thread_height > 0 then
        handle.reserve_line = anchor_0 + 1
        handle.reserve_above = true
      end
      handle.extmark_id = ifloat.reserve_space(
        handle.diff_buf, handle.reserve_line, total_height + 2, handle.reserve_above)

      -- Self-heal: re-reserve space when diff buffer is rewritten (e.g. AI suggestions)
      local heal_pending = false
      vim.api.nvim_buf_attach(handle.diff_buf, false, {
        on_lines = function()
          if handle.closed then return true end
          if heal_pending then return end
          heal_pending = true
          vim.schedule(function()
            heal_pending = false
            if handle.closed then return end
            if not vim.api.nvim_buf_is_valid(handle.diff_buf) then return end
            local cur_h = vim.api.nvim_win_is_valid(handle.win)
              and vim.api.nvim_win_get_height(handle.win) or total_height
            handle.extmark_id = ifloat.reserve_space(
              handle.diff_buf, handle.reserve_line, cur_h + 2, handle.reserve_above)
            if #handle.line_hl_ids > 0 then
              ifloat.clear_line_hl(handle.diff_buf, handle.line_hl_ids)
              handle.line_hl_ids = ifloat.highlight_lines(
                handle.diff_buf, opts.anchor_start or opts.anchor_line, opts.anchor_line)
            end
          end)
        end,
      })
    end

    handle.win = vim.api.nvim_open_win(buf, true, {
      relative = "win",
      win = opts.win_id,
      bufpos = { anchor_0, 0 },
      width = width - (opts.is_reply and 4 or 0),
      height = total_height,
      row = is_edit_overlay and (opts.spacer_offset + 1) or (opts.thread_height or 0) + 1,
      col = opts.is_reply and 7 or 3,
      style = "minimal",
      border = ifloat.border(opts.action_type),
      title = styled_title,
      title_pos = "center",
      footer = styled_footer,
      footer_pos = "center",
      noautocmd = true,
    })
  else
    -- Fallback: centered editor-relative float
    local width = math.min(100, math.floor(vim.o.columns * 0.6))
    local height = math.max(total_height, 10)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    handle.win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = ifloat.border(opts.action_type),
      title = styled_title,
      title_pos = "center",
      footer = styled_footer,
      footer_pos = "center",
      noautocmd = true,
    })
  end

  local function apply_no_dim()
    if vim.api.nvim_win_is_valid(handle.win) then
      vim.api.nvim_set_option_value("winblend", 0, { win = handle.win })
      vim.api.nvim_set_option_value("winhighlight", "NormalFloat:Normal", { win = handle.win })
      vim.api.nvim_set_option_value("wrap", true, { win = handle.win })
    end
  end
  apply_no_dim()

  vim.api.nvim_create_autocmd("WinEnter", {
    buffer = buf,
    callback = function()
      if handle.closed then return true end
      apply_no_dim()
    end,
  })

  -- Place cursor on first line
  pcall(vim.api.nvim_win_set_cursor, handle.win, { 1, 0 })

  --- Close the float and clean up all associated resources.
  function handle.close()
    if handle.closed then return end
    handle.closed = true
    vim.cmd("stopinsert")
    pcall(vim.api.nvim_win_close, handle.win, true)
    if handle.extmark_id and handle.diff_buf then
      ifloat.clear_space(handle.diff_buf, handle.extmark_id)
    end
    if handle.diff_buf and #handle.line_hl_ids > 0 then
      ifloat.clear_line_hl(handle.diff_buf, handle.line_hl_ids)
    end
    if opts.on_close then opts.on_close() end
  end

  --- Return editable lines from the buffer (skipping header).
  function handle.get_text()
    local lines = vim.api.nvim_buf_get_lines(buf, header_count, -1, false)
    return vim.trim(table.concat(lines, "\n"))
  end

  -- Auto-resize on text change
  local resize_timer = nil
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if handle.closed then return true end
      if resize_timer then
        vim.fn.timer_stop(resize_timer)
      end
      resize_timer = vim.fn.timer_start(15, function()
        resize_timer = nil
        if handle.closed or not vim.api.nvim_buf_is_valid(buf) then return end
        -- Count display lines (accounting for wrap)
        local win_w = vim.api.nvim_win_is_valid(handle.win)
          and vim.api.nvim_win_get_width(handle.win) or 1
        local display_lines = 0
        local lines = vim.api.nvim_buf_get_lines(buf, header_count, -1, false)
        for _, l in ipairs(lines) do
          display_lines = display_lines + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / win_w))
        end
        local new_height = ifloat.compute_height(display_lines, header_count)
        if vim.api.nvim_win_is_valid(handle.win) then
          vim.api.nvim_win_set_height(handle.win, new_height)
        end
        if opts.spacer_offset ~= nil and opts.on_resize then
          opts.on_resize(new_height)
        elseif handle.extmark_id and handle.diff_buf
            and vim.api.nvim_buf_is_valid(handle.diff_buf) then
          ifloat.update_space(
            handle.diff_buf, handle.extmark_id,
            handle.reserve_line, new_height + 2, handle.reserve_above)
          -- Scroll diff so the reserved space stays visible
          if opts.win_id and vim.api.nvim_win_is_valid(opts.win_id) then
            local target = handle.reserve_line + new_height + 3  -- bottom of reserved space (1-indexed)
            local diff_height = vim.api.nvim_win_get_height(opts.win_id)
            local topline = math.max(1, target - diff_height + 1)
            local cur_top = vim.fn.getwininfo(opts.win_id)[1].topline
            if topline > cur_top then
              vim.api.nvim_win_call(opts.win_id, function()
                vim.fn.winrestview({ topline = topline })
              end)
            end
          end
          -- When float is constrained by window bottom and extends upward,
          -- scroll diff so the anchor stays visible above the float.
          if opts.win_id and vim.api.nvim_win_is_valid(opts.win_id)
              and vim.api.nvim_win_is_valid(handle.win) then
            local float_visual = new_height + (opts.thread_height or 0) + 4
            local win_h = vim.api.nvim_win_get_height(opts.win_id)
            local max_row = win_h - float_visual
            if max_row >= 0 then
              local win_pos = vim.api.nvim_win_get_position(opts.win_id)
              local anchor_scr = vim.fn.screenpos(opts.win_id, opts.anchor_line, 1)
              if anchor_scr.row > 0 then
                local anchor_vrow = anchor_scr.row - 1 - win_pos[1]
                if anchor_vrow > max_row then
                  local scroll_by = anchor_vrow - max_row
                  vim.api.nvim_win_call(opts.win_id, function()
                    vim.cmd('execute "normal! ' .. scroll_by .. '\\<C-e>"')
                  end)
                end
              end
            end
          end
        end
      end)
    end,
  })

  -- WinClosed guard
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(handle.win),
    once = true,
    callback = function() handle.close() end,
  })

  return handle
end

return M
