local markdown = require("codereview.ui.markdown")
local detail = require("codereview.mr.detail")
local M = {}

--- Open a floating popup for multi-line comment input.
--- @param title string  Title shown in the border
--- @param callback fun(text: string)  Called with the joined text on submit
--- @param opts? table  { anchor_line?, win_id?, action_type?, context_text?, prefill? }
local function open_input_popup(title, callback, opts)
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

  local footer = " <C-CR> submit  <C-p> preview  q cancel "

  local win, extmark_id
  local diff_buf
  local line_hl_ids = {}

  if use_inline then
    local anchor_0 = opts.anchor_line - 1  -- convert to 0-indexed
    diff_buf = vim.api.nvim_win_get_buf(opts.win_id)

    -- Highlight the target line(s)
    local hl_start = opts.anchor_start or opts.anchor_line
    line_hl_ids = ifloat.highlight_lines(diff_buf, hl_start, opts.anchor_line)
    local win_width = vim.api.nvim_win_get_width(opts.win_id)
    local width = win_width - 4  -- small margin

    -- Reserve space
    extmark_id = ifloat.reserve_space(diff_buf, anchor_0, total_height + 2)

    win = vim.api.nvim_open_win(buf, true, {
      relative = "win",
      win = opts.win_id,
      bufpos = { anchor_0, 0 },
      width = width,
      height = total_height,
      row = 1,
      col = 1,
      style = "minimal",
      border = ifloat.border(opts.action_type),
      title = " " .. title .. " ",
      title_pos = "center",
      footer = footer,
      footer_pos = "center",
      noautocmd = true,
    })
  else
    -- Fallback: centered editor-relative float
    local width = 70
    local row = math.floor((vim.o.lines - total_height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = total_height,
      row = row,
      col = col,
      style = "minimal",
      border = ifloat.border(opts.action_type),
      title = " " .. title .. " ",
      title_pos = "center",
      footer = footer,
      footer_pos = "center",
      noautocmd = true,
    })
  end

  vim.api.nvim_set_option_value("winblend", 0, { win = win })
  vim.api.nvim_set_option_value("winhighlight", "NormalFloat:Normal", { win = win })

  -- Place cursor on first line
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })

  -- Start in insert for new comments, normal for edits
  if opts.action_type == "edit" then
    vim.cmd("stopinsert")
  else
    vim.cmd("startinsert")
  end

  local closed = false
  local function close()
    if closed then return end
    closed = true
    vim.cmd("stopinsert")
    pcall(vim.api.nvim_win_close, win, true)
    if extmark_id and diff_buf then
      ifloat.clear_space(diff_buf, extmark_id)
    end
    if diff_buf and #line_hl_ids > 0 then
      ifloat.clear_line_hl(diff_buf, line_hl_ids)
    end
  end

  local function submit()
    -- Read only editable lines (skip header)
    local lines = vim.api.nvim_buf_get_lines(buf, header_count, -1, false)
    close()
    local text = vim.trim(table.concat(lines, "\n"))
    if text ~= "" then
      callback(text)
    end
  end

  -- Auto-resize on text change
  local resize_timer = nil
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if closed then return true end
      if resize_timer then
        vim.fn.timer_stop(resize_timer)
      end
      resize_timer = vim.fn.timer_start(15, function()
        resize_timer = nil
        if closed or not vim.api.nvim_buf_is_valid(buf) then return end
        local line_count = vim.api.nvim_buf_line_count(buf) - header_count
        local new_height = ifloat.compute_height(line_count, header_count)
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_set_height(win, new_height)
        end
        if extmark_id and diff_buf and vim.api.nvim_buf_is_valid(diff_buf) then
          ifloat.update_space(diff_buf, extmark_id, opts.anchor_line - 1, new_height + 2)
        end
      end)
    end,
  })

  -- WinClosed guard
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() close() end,
  })

  -- Preview state
  local preview_buf = nil
  local saved_cursor = nil

  local function toggle_preview()
    if closed then return end

    if preview_buf and vim.api.nvim_win_get_buf(win) == preview_buf then
      -- Switch back to edit
      vim.api.nvim_win_set_buf(win, buf)
      if saved_cursor then
        pcall(vim.api.nvim_win_set_cursor, win, saved_cursor)
      end
      vim.api.nvim_win_set_config(win, { title = " " .. title .. " " })
      preview_buf = nil
    else
      -- Switch to preview
      saved_cursor = vim.api.nvim_win_get_cursor(win)
      local edit_lines = vim.api.nvim_buf_get_lines(buf, header_count, -1, false)
      preview_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, edit_lines)
      vim.bo[preview_buf].modifiable = false
      vim.bo[preview_buf].bufhidden = "wipe"
      markdown.set_buf_markdown(preview_buf)
      vim.api.nvim_win_set_buf(win, preview_buf)
      vim.api.nvim_win_set_config(win, { title = " Preview " })
      -- Preview keymaps
      local pmap = { buffer = preview_buf, nowait = true }
      vim.keymap.set({ "n", "i" }, "<C-p>", toggle_preview, pmap)
      vim.keymap.set("n", "q", close, pmap)
      vim.keymap.set("n", "<Esc>", close, pmap)
    end
  end

  -- Keymaps
  local map_opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q", close, map_opts)
  vim.keymap.set("n", "<Esc>", close, map_opts)
  vim.keymap.set({ "n", "i" }, "<C-CR>", submit, map_opts)
  vim.keymap.set({ "n", "i" }, "<C-p>", toggle_preview, map_opts)
end

local function get_provider()
  local providers = require("codereview.providers")
  local client = require("codereview.api.client")
  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify(err or "Could not detect platform", vim.log.levels.ERROR)
    return nil, nil, nil
  end
  return provider, client, ctx
end

function M.build_thread_lines(disc)
  local lines = {}
  local notes = disc.notes or {}
  if #notes == 0 then return lines end

  local first = notes[1]

  -- Resolved status header
  local resolved_str = ""
  if first.resolvable then
    if first.resolved then
      local by = first.resolved_by or "?"
      resolved_str = "  [Resolved by @" .. by .. "]"
    else
      resolved_str = "  [Unresolved]"
    end
  end

  table.insert(lines, string.format(
    "@%s (%s)%s",
    first.author,
    detail.format_time(first.created_at),
    resolved_str
  ))

  for _, body_line in ipairs(markdown.to_lines(first.body)) do
    table.insert(lines, "  " .. body_line)
  end

  -- Replies
  for i = 2, #notes do
    local reply = notes[i]
    table.insert(lines, "")
    table.insert(lines, string.format(
      "  -> @%s (%s):",
      reply.author,
      detail.format_time(reply.created_at)
    ))
    for _, body_line in ipairs(markdown.to_lines(reply.body)) do
      table.insert(lines, "     " .. body_line)
    end
  end

  return lines
end

function M.show_thread(disc, mr)
  local thread_lines = M.build_thread_lines(disc)

  local hints = {
    "",
    "[r] reply  [R] un/resolve  [o] open browser  [q] close",
  }

  local all_lines = {}
  for _, l in ipairs(thread_lines) do table.insert(all_lines, l) end
  for _, l in ipairs(hints) do table.insert(all_lines, l) end

  local width = 70
  local height = math.min(#all_lines + 2, 30)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  markdown.set_buf_markdown(buf)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Thread ",
    title_pos = "center",
  })

  local close = function() pcall(vim.api.nvim_win_close, win, true) end
  local map_opts = { buffer = buf, nowait = true }

  vim.keymap.set("n", "q", close, map_opts)
  vim.keymap.set("n", "r", function()
    close()
    M.reply(disc, mr)
  end, map_opts)
  vim.keymap.set("n", "R", function()
    close()
    M.resolve_toggle(disc, mr, function()
      vim.notify("Resolve status toggled", vim.log.levels.INFO)
    end)
  end, map_opts)
  vim.keymap.set("n", "o", function()
    if mr and mr.web_url then
      vim.ui.open(mr.web_url)
    end
  end, map_opts)
end

function M.reply(disc, mr, on_success, opts)
  opts = opts or {}
  if not opts.action_type then opts.action_type = "reply" end
  if not opts.context_text and disc.notes and disc.notes[1] then
    local first = disc.notes[1]
    local snippet = (first.body or ""):sub(1, 60)
    opts.context_text = "@" .. (first.author or "?") .. ": " .. snippet
  end
  open_input_popup("Reply", function(text)
    local provider, client, ctx = get_provider()
    if not provider then return end
    local _, err = provider.reply_to_discussion(client, ctx, mr, disc.id, text)
    if err then
      vim.notify("Failed to post reply: " .. err, vim.log.levels.ERROR)
    else
      vim.notify("Reply posted", vim.log.levels.INFO)
      if on_success then on_success() end
    end
  end, opts)
end

function M.resolve_toggle(disc, mr, callback)
  local first = disc.notes and disc.notes[1]
  if not first then return end

  local provider, client, ctx = get_provider()
  if not provider then return end

  local currently_resolved = first.resolved
  local _, err = provider.resolve_discussion(client, ctx, mr, disc.id, not currently_resolved)
  if err then
    vim.notify("Failed to toggle resolve: " .. err, vim.log.levels.ERROR)
  elseif callback then
    callback()
  end
end

function M.create_inline(mr, old_path, new_path, old_line, new_line, on_success, opts)
  open_input_popup("Inline Comment", function(text)
    local provider, client, ctx = get_provider()
    if not provider then return end
    local position = {
      old_path = old_path,
      new_path = new_path,
      old_line = old_line,
      new_line = new_line,
    }
    local _, err = provider.post_comment(client, ctx, mr, text, position)
    if err then
      vim.notify("Failed to post comment: " .. err, vim.log.levels.ERROR)
    else
      vim.notify("Comment posted", vim.log.levels.INFO)
      if on_success then on_success() end
    end
  end, opts)
end

function M.create_inline_range(mr, old_path, new_path, start_pos, end_pos, on_success, opts)
  open_input_popup("Range Comment", function(text)
    local provider, client, ctx = get_provider()
    if not provider then return end
    local _, err = provider.post_range_comment(client, ctx, mr, text, old_path, new_path, start_pos, end_pos)
    if err then
      vim.notify("Failed to post range comment: " .. err, vim.log.levels.ERROR)
    else
      vim.notify("Range comment posted", vim.log.levels.INFO)
      if on_success then on_success() end
    end
  end, opts)
end

function M.create_inline_draft(mr, new_path, new_line, on_success, opts)
  open_input_popup("Draft Comment", function(text)
    local provider, client, ctx = get_provider()
    if not provider then return end
    local _, err = provider.create_draft_comment(client, ctx, mr, {
      body = text,
      path = new_path,
      line = new_line,
    })
    if err then
      vim.notify("Failed to create draft comment: " .. err, vim.log.levels.ERROR)
    else
      vim.notify("Draft comment created", vim.log.levels.INFO)
      if on_success then on_success(text) end
    end
  end, opts)
end

function M.create_inline_range_draft(mr, new_path, start_line, end_line, on_success, opts)
  open_input_popup("Draft Comment", function(text)
    local provider, client, ctx = get_provider()
    if not provider then return end
    local _, err = provider.create_draft_comment(client, ctx, mr, {
      body = text,
      path = new_path,
      line = end_line,
    })
    if err then
      vim.notify("Failed to create draft comment: " .. err, vim.log.levels.ERROR)
    else
      vim.notify("Draft comment created", vim.log.levels.INFO)
      if on_success then on_success(text) end
    end
  end, opts)
end

function M.create_mr_comment(review, provider, ctx, on_success)
  -- No opts: summary view has no line context, always uses fallback centered float
  open_input_popup("Comment on MR", function(text)
    if not provider or not ctx then return end
    local client_mod = require("codereview.api.client")
    local _, err = provider.post_comment(client_mod, ctx, review, text, nil)
    if err then
      vim.notify("Failed to post comment: " .. err, vim.log.levels.ERROR)
    else
      vim.notify("Comment posted", vim.log.levels.INFO)
      if on_success then on_success() end
    end
  end)
end

return M
