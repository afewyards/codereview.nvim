local markdown = require("codereview.ui.markdown")
local detail = require("codereview.mr.detail")
local M = {}

--- Open a floating popup for multi-line comment input.
--- @param title string  Title shown in the border
--- @param callback fun(text: string)  Called with the joined text on submit
local function open_input_popup(title, callback)
  local width = 70
  local height = 8
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    footer = " <C-CR> submit  q/Esc cancel ",
    footer_pos = "center",
  })

  vim.cmd("startinsert")

  local closed = false
  local function close()
    if closed then return end
    closed = true
    vim.cmd("stopinsert")
    pcall(vim.api.nvim_win_close, win, true)
  end

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    close()
    local text = vim.fn.join(lines, "\n")
    text = vim.trim(text)
    if text ~= "" then
      callback(text)
    end
  end

  local map_opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q", close, map_opts)
  vim.keymap.set("n", "<Esc>", close, map_opts)
  vim.keymap.set({ "n", "i" }, "<C-CR>", submit, map_opts)
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

function M.reply(disc, mr, on_success)
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
  end)
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

function M.create_inline(mr, old_path, new_path, old_line, new_line, on_success)
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
  end)
end

function M.create_inline_range(mr, old_path, new_path, start_pos, end_pos, on_success)
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
  end)
end

function M.create_inline_draft(mr, new_path, new_line, on_success)
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
      if on_success then on_success() end
    end
  end)
end

function M.create_inline_range_draft(mr, new_path, start_line, end_line, on_success)
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
      if on_success then on_success() end
    end
  end)
end

function M.create_mr_comment(review, provider, ctx, on_success)
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
