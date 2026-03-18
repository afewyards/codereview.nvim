local markdown = require("codereview.ui.markdown")
local detail = require("codereview.mr.detail")
local comment_float = require("codereview.mr.comment_float")
local M = {}

--- Open a floating popup for multi-line comment input.
--- @param title string  Title shown in the border
--- @param callback fun(text: string)  Called with the joined text on submit
--- @param opts? table  { anchor_line?, win_id?, action_type?, context_text?, prefill? }
function M.open_input_popup(title, callback, opts)
  opts = opts or {}

  -- Open the float and get back a handle with buf/win/close/get_text
  local handle = comment_float.open(title, opts)
  local buf = handle.buf
  local win = handle.win

  local function close()
    handle.close()
  end

  local function submit()
    local text = handle.get_text()
    close()
    if text and text ~= "" then
      callback(text)
    end
  end

  -- Start in insert for new comments, normal for edits
  if opts.action_type == "edit" then
    vim.cmd("stopinsert")
  else
    vim.cmd("startinsert")
  end

  -- Close on leaving the float window
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    callback = function()
      if handle.closed then
        return true
      end
      local text = handle.get_text()
      if text and text ~= "" then
        local choice = vim.fn.confirm("Discard comment?", "&Discard\n&Submit\n&Cancel", 3)
        if choice == 1 then
          close()
        elseif choice == 2 then
          submit()
        else
          -- Cancel — defer refocus so it runs after the window switch completes
          vim.schedule(function()
            if not handle.closed and vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_set_current_win(win)
            end
          end)
        end
      else
        close()
      end
      return true
    end,
  })

  -- Keymaps
  local map_opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q", close, map_opts)
  vim.keymap.set("n", "<Esc>", close, map_opts)
  vim.keymap.set({ "n", "i" }, "<C-CR>", submit, map_opts)
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, map_opts)
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
  if #notes == 0 then
    return lines
  end

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

  table.insert(lines, string.format("@%s (%s)%s", first.author, detail.format_time(first.created_at), resolved_str))

  for _, body_line in ipairs(markdown.to_lines(first.body)) do
    table.insert(lines, "  " .. body_line)
  end

  -- Replies
  for i = 2, #notes do
    local reply = notes[i]
    table.insert(lines, "")
    table.insert(lines, string.format("  -> @%s (%s):", reply.author, detail.format_time(reply.created_at)))
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
  for _, l in ipairs(thread_lines) do
    table.insert(all_lines, l)
  end
  for _, l in ipairs(hints) do
    table.insert(all_lines, l)
  end

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

  local close = function()
    pcall(vim.api.nvim_win_close, win, true)
  end
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

function M.reply(disc, mr, optimistic, opts)
  opts = opts or {}
  if not opts.action_type then
    opts.action_type = "reply"
  end
  if not opts.context_text and disc.notes and disc.notes[1] then
    local first = disc.notes[1]
    local snippet = (first.body or ""):sub(1, 60)
    opts.context_text = "@" .. (first.author or "?") .. ": " .. snippet
  end
  M.open_input_popup("Reply", function(text)
    local note
    if optimistic and optimistic.add_reply then
      note = optimistic.add_reply(text)
    end
    vim.schedule(function()
      local async_client = require("codereview.api.async_client")
      local provider, _, ctx = get_provider()
      if not provider then
        if note and optimistic.remove_reply then
          optimistic.remove_reply(disc, note)
        end
        return
      end
      M.post_with_retry(function()
        return provider.reply_to_discussion(async_client, ctx, mr, disc.id, text)
      end, function()
        vim.notify("Reply posted", vim.log.levels.INFO)
        if optimistic and optimistic.refresh then
          optimistic.refresh()
        end
      end, function(err)
        vim.notify("Failed to post reply: " .. err, vim.log.levels.ERROR)
        if note and optimistic.mark_reply_failed then
          optimistic.mark_reply_failed(note)
        end
      end)
    end)
  end, opts)
end

--- Edit an existing note. Opens input popup with prefill, calls provider edit_note on submit.
--- @param disc table  discussion containing the note
--- @param note table  the note to edit
--- @param mr table    the MR/PR object
--- @param on_success fun()  called after successful edit (triggers re-render)
--- @param opts table?  optional popup opts (win_id, anchor_line, etc.)
function M.edit_note(disc, note, mr, on_success, opts)
  opts = opts or {}
  opts.action_type = "edit"
  opts.prefill = note.body
  M.open_input_popup("Edit comment", function(text)
    if text == note.body then
      return
    end -- no change
    require("plenary.async").run(function()
      local async_client = require("codereview.api.async_client")
      local provider, _, ctx = get_provider()
      if not provider then
        return
      end
      local _, err = provider.edit_note(async_client, ctx, mr, disc.id, note.id, text)
      vim.schedule(function()
        if err then
          vim.notify("Edit failed: " .. err, vim.log.levels.ERROR)
          return
        end
        note.body = text
        if on_success then
          on_success()
        end
      end)
    end)
  end, opts)
end

--- Delete a note. Shows Yes/No confirmation, calls provider delete_note on confirm.
--- @param disc table  discussion containing the note
--- @param note table  the note to delete
--- @param mr table    the MR/PR object
--- @param on_success fun(result?: table)  called after successful delete
function M.delete_note(disc, note, mr, on_success)
  vim.ui.input({ prompt = "Delete this comment? (Y/n): ", default = "y" }, function(input)
    if not input or input:lower():match("^n") then
      return
    end
    require("plenary.async").run(function()
      local async_client = require("codereview.api.async_client")
      local provider, _, ctx = get_provider()
      if not provider then
        return
      end
      local _, err = provider.delete_note(async_client, ctx, mr, disc.id, note.id)
      vim.schedule(function()
        if err then
          vim.notify("Delete failed: " .. err, vim.log.levels.ERROR)
          return
        end
        -- Remove note from discussion
        for i, n in ipairs(disc.notes) do
          if n.id == note.id then
            table.remove(disc.notes, i)
            break
          end
        end
        -- If thread is now empty, signal caller to remove the discussion
        if #disc.notes == 0 then
          if on_success then
            on_success({ removed_disc = true })
          end
        else
          if on_success then
            on_success()
          end
        end
      end)
    end)
  end)
end

--- Delete a draft comment. Confirmation prompt, calls provider delete_draft_note.
--- @param disc table  the draft discussion (must have server_draft_id)
--- @param mr table    the MR/PR object
--- @param on_success fun()  called after successful delete
function M.delete_draft(disc, mr, on_success)
  if not disc.server_draft_id then
    vim.notify("Cannot delete: draft has no server ID", vim.log.levels.ERROR)
    return
  end
  vim.ui.input({ prompt = "Delete this draft comment? (Y/n): ", default = "y" }, function(input)
    if not input or input:lower():match("^n") then
      return
    end
    require("plenary.async").run(function()
      local async_client = require("codereview.api.async_client")
      local provider, _, ctx = get_provider()
      if not provider then
        return
      end
      if not provider.delete_draft_note then
        vim.schedule(function()
          vim.notify("Draft deletion not supported on this platform", vim.log.levels.WARN)
        end)
        return
      end
      local _, err = provider.delete_draft_note(async_client, ctx, mr, disc.server_draft_id)
      vim.schedule(function()
        if err then
          vim.notify("Delete draft failed: " .. err, vim.log.levels.ERROR)
          return
        end
        if on_success then
          on_success()
        end
      end)
    end)
  end)
end

function M.resolve_toggle(disc, mr, callback)
  local first = disc.notes and disc.notes[1]
  if not first then
    return
  end

  local currently_resolved = first.resolved
  -- Optimistic update
  for _, note in ipairs(disc.notes) do
    if note.resolvable ~= nil then
      note.resolved = not currently_resolved
    end
  end
  disc.resolved = not currently_resolved
  if callback then
    callback()
  end

  -- Fire async
  require("plenary.async").run(function()
    local async_client = require("codereview.api.async_client")
    local provider, _, ctx = get_provider()
    if not provider then
      return
    end
    local _, err = provider.resolve_discussion(async_client, ctx, mr, disc.id, not currently_resolved, disc.node_id)
    if err then
      vim.schedule(function()
        vim.notify("Failed to toggle resolve: " .. err, vim.log.levels.ERROR)
      end)
    end
  end)
end

--- Unified comment creation for all inline comment variants.
--- @param mr table  The MR/PR object
--- @param opts table  Options:
---   opts.title: string  popup title
---   opts.api_fn: fun(provider, client, ctx, mr, text) → result, err  the API call
---   opts.optimistic: { add, remove, mark_failed, refresh }? or nil (non-draft path)
---   opts.use_retry: bool  whether to use post_with_retry (non-draft path)
---   opts.success_msg: string  notification on success
---   opts.failure_msg: string  prefix for error notification
---   opts.on_success: fun(text)?  called after success (draft path)
---   opts.popup_opts: table?  passed to open_input_popup
function M.create_comment(mr, opts)
  opts = opts or {}
  local title = opts.title or "Comment"
  local popup_opts = opts.popup_opts

  M.open_input_popup(title, function(text)
    if opts.optimistic and opts.optimistic.add then
      local disc = opts.optimistic.add(text)

      -- Yield to event loop so Neovim redraws the optimistic comment before blocking on API
      vim.schedule(function()
        local async_client = require("codereview.api.async_client")
        local provider, _, ctx = get_provider()
        if not provider then
          if disc and opts.optimistic.remove then
            opts.optimistic.remove(disc)
          end
          return
        end
        M.post_with_retry(function()
          return opts.api_fn(provider, async_client, ctx, mr, text)
        end, function()
          vim.notify(opts.success_msg or "Comment posted", vim.log.levels.INFO)
          if opts.optimistic.refresh then
            opts.optimistic.refresh()
          end
        end, function(err)
          vim.notify((opts.failure_msg or "Failed to post comment") .. ": " .. err, vim.log.levels.ERROR)
          if disc and opts.optimistic.mark_failed then
            opts.optimistic.mark_failed(disc)
          end
        end)
      end)
    elseif opts.use_retry then
      -- Retry path without optimistic UI
      vim.schedule(function()
        local async_client = require("codereview.api.async_client")
        local provider, _, ctx = get_provider()
        if not provider then
          return
        end
        M.post_with_retry(function()
          return opts.api_fn(provider, async_client, ctx, mr, text)
        end, function()
          vim.notify(opts.success_msg or "Comment posted", vim.log.levels.INFO)
        end, function(err)
          vim.notify((opts.failure_msg or "Failed to post comment") .. ": " .. err, vim.log.levels.ERROR)
        end)
      end)
    else
      -- Draft path: async, no optimistic, no retry
      require("plenary.async").run(function()
        local async_client = require("codereview.api.async_client")
        local provider, _, ctx = get_provider()
        if not provider then
          return
        end
        local result, err = opts.api_fn(provider, async_client, ctx, mr, text)
        vim.schedule(function()
          if err then
            vim.notify((opts.failure_msg or "Failed to create draft comment") .. ": " .. err, vim.log.levels.ERROR)
          else
            vim.notify(opts.success_msg or "Draft comment created", vim.log.levels.INFO)
            if opts.on_success then
              opts.on_success(text, result)
            end
          end
        end)
      end)
    end
  end, popup_opts)
end

--- Create an inline comment at a specific line.
--- @param mr table  the MR/PR object
--- @param old_path string
--- @param new_path string
--- @param old_line number|nil
--- @param new_line number|nil
--- @param optimistic table|nil  optimistic callbacks {add, remove, mark_failed, refresh}
--- @param popup_opts table|nil  popup positioning opts
function M.create_inline(mr, old_path, new_path, old_line, new_line, optimistic, popup_opts)
  M.create_comment(mr, {
    title = "Inline Comment",
    api_fn = function(provider, client, ctx, review, text)
      return provider.post_comment(client, ctx, review, text, {
        old_path = old_path,
        new_path = new_path,
        old_line = old_line,
        new_line = new_line,
      })
    end,
    optimistic = optimistic,
    success_msg = "Comment posted",
    failure_msg = "Failed to post comment",
    popup_opts = popup_opts,
  })
end

--- Create a range comment over multiple lines.
--- @param mr table  the MR/PR object
--- @param old_path string
--- @param new_path string
--- @param start_pos table  { old_line, new_line }
--- @param end_pos table  { old_line, new_line }
--- @param optimistic table|nil  optimistic callbacks {add, remove, mark_failed, refresh}
--- @param popup_opts table|nil  popup positioning opts
function M.create_inline_range(mr, old_path, new_path, start_pos, end_pos, optimistic, popup_opts)
  M.create_comment(mr, {
    title = "Range Comment",
    api_fn = function(provider, client, ctx, review, text)
      return provider.post_range_comment(client, ctx, review, text, old_path, new_path, start_pos, end_pos)
    end,
    optimistic = optimistic,
    success_msg = "Range comment posted",
    failure_msg = "Failed to post range comment",
    popup_opts = popup_opts,
  })
end

function M.create_mr_comment(review, provider, ctx, on_success)
  -- No opts: summary view has no line context, always uses fallback centered float
  M.open_input_popup("Comment on MR", function(text)
    if not provider or not ctx then
      return
    end
    require("plenary.async").run(function()
      local async_client = require("codereview.api.async_client")
      local _, err = provider.post_comment(async_client, ctx, review, text, nil)
      vim.schedule(function()
        if err then
          vim.notify("Failed to post comment: " .. err, vim.log.levels.ERROR)
        else
          vim.notify("Comment posted", vim.log.levels.INFO)
          if on_success then
            on_success()
          end
        end
      end)
    end)
  end)
end

--- Update note.reactions in-place for optimistic UI.
local function update_note_reactions(note, emoji_name, reacted)
  note.reactions = note.reactions or {}
  for _, r in ipairs(note.reactions) do
    if r.name == emoji_name then
      r.reacted = reacted
      r.count = math.max(0, r.count + (reacted and 1 or -1))
      return
    end
  end
  -- New reaction entry
  if reacted then
    table.insert(note.reactions, { name = emoji_name, count = 1, reacted = true })
  end
end

--- React (add/remove) an emoji reaction to a note.
--- @param note table  the note to react to
--- @param mr table    the MR/PR object
--- @param on_success fun()  called after successful reaction (triggers re-render)
function M.react_to_note(_disc, note, mr, on_success) -- luacheck: ignore _disc
  require("codereview.mr.reaction_float").open(note, {
    on_toggle = function(emoji_name, reacted)
      -- Optimistic: update note.reactions in-place and re-render immediately
      update_note_reactions(note, emoji_name, reacted)
      if on_success then
        on_success()
      end

      -- Fire API call in the background
      require("plenary.async").run(function()
        local async_client = require("codereview.api.async_client")
        local provider, _, ctx = get_provider()
        if not provider then
          return
        end
        local _, err
        if provider.name == "github" then
          if not note.node_id then
            vim.schedule(function()
              vim.notify("Cannot react: note missing node_id (try refreshing)", vim.log.levels.ERROR)
            end)
            return
          end
          if reacted then
            _, err = provider.add_reaction(async_client, ctx, mr, note.node_id, emoji_name)
          else
            _, err = provider.remove_reaction(async_client, ctx, mr, note.node_id, emoji_name)
          end
        elseif provider.name == "gitlab" then
          if reacted then
            _, err = provider.add_reaction(async_client, ctx, mr, note.id, emoji_name)
          else
            local award_id = nil
            local current_user = provider.get_current_user(async_client, ctx)
            for _, reaction in ipairs(note.reactions or {}) do
              if reaction.name == emoji_name then
                for _, award in ipairs(reaction.awards or {}) do
                  if award.user == current_user then
                    award_id = award.id
                    break
                  end
                end
                break
              end
            end
            if not award_id then
              vim.schedule(function()
                vim.notify("Could not find your reaction to remove", vim.log.levels.ERROR)
              end)
              return
            end
            _, err = provider.remove_reaction(async_client, ctx, mr, note.id, award_id)
          end
        end
        if err then
          -- Rollback optimistic update on error
          vim.schedule(function()
            update_note_reactions(note, emoji_name, not reacted)
            if on_success then
              on_success()
            end
            vim.notify("Reaction failed: " .. tostring(err), vim.log.levels.ERROR)
          end)
        end
      end)
    end,
  })
end

function M.post_with_retry(api_fn, on_success, on_failure, opts)
  opts = opts or {}
  local max = opts.max_retries or 3
  local delay = opts.delay_ms or 2000

  require("plenary.async").run(function()
    for attempt = 1, max do
      local _, err = api_fn()
      if not err then
        vim.schedule(on_success)
        return
      end
      if attempt >= max then
        vim.schedule(function()
          on_failure(err)
        end)
        return
      end
      require("plenary.async.util").sleep(delay)
    end
  end)
end

return M
