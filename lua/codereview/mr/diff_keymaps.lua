-- lua/codereview/mr/diff_keymaps.lua
-- Keymap setup for the diff viewer.
-- Extracted from diff.lua to keep the main module focused on open() and state access.
--
-- Entry point: M.setup_keymaps(state, layout, active_states)
--   state        – the diff viewer state table (created by diff_state.create_state)
--   layout       – the split layout (main_buf, sidebar_buf, main_win, sidebar_win)
--   active_states – module-level table in diff.lua; this module writes to it so that
--                   diff.get_state() returns the live state for the current main_buf.

local M = {}

local config = require("codereview.config")
local tvl = require("codereview.mr.thread_virt_lines")
local diff_state = require("codereview.mr.diff_state")
local diff_render = require("codereview.mr.diff_render")
local diff_sidebar = require("codereview.mr.diff_sidebar")
local diff_nav = require("codereview.mr.diff_nav")
local diff_comments = require("codereview.mr.diff_comments")
local tracker = require("codereview.mr.review_tracker")
local wrap_text = tvl.wrap_text

-- Namespace — same name returns same ID, safe to redeclare
local AIDRAFT_NS = vim.api.nvim_create_namespace("codereview_ai_draft")

--- Set up all keymaps, autocmds, and the active_states entry for a diff layout.
--- @param state table   diff viewer state (from diff_state.create_state)
--- @param layout table  split layout
--- @param active_states table  module-level table shared with diff.get_state()
function M.setup_keymaps(state, layout, active_states)
  local km = require("codereview.keymaps")
  local main_buf = layout.main_buf
  local sidebar_buf = layout.sidebar_buf
  local opts = { noremap = true, silent = true, nowait = true }

  -- map() is kept for NON-registry keymaps only:
  -- <CR> load-more on main_buf, <CR> file-select on sidebar_buf,
  -- and float keymaps inside the edit_suggestion handler.
  local function map(buf, mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, vim.tbl_extend("force", opts, { buffer = buf }))
  end

  -- Track active state for external access (e.g. from AI review module)
  active_states[main_buf] = { state = state, layout = layout }

  -- ── Local helper functions (must be defined before callbacks table) ──────────

  -- Re-render discussions without re-fetching from API
  local function rerender_view_sync()
    local view = vim.fn.winsaveview()

    if state.scroll_mode then
      local result = diff_render.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user, state.editing_note, state.git_diff_cache)
      diff_state.apply_scroll_result(state, result)
    else
      local file = state.files and state.files[state.current_file]
      if file then
        local ld, rd, ra = diff_render.render_file_diff(layout.main_buf, file, state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user, state.editing_note, state.git_diff_cache)
        diff_state.apply_file_result(state, state.current_file, ld, rd, ra)
      end
    end

    -- Clamp cursor to buffer bounds then restore scroll position
    local max_line = vim.api.nvim_buf_line_count(layout.main_buf)
    view.lnum = math.min(view.lnum, max_line)
    view.topline = math.min(view.topline, max_line)
    vim.fn.winrestview(view)
  end

  local render_timer = nil

  local function rerender_view()
    if render_timer then
      pcall(vim.fn.timer_stop, render_timer)
    end
    render_timer = vim.fn.timer_start(20, function()
      render_timer = nil
      vim.schedule(function()
        rerender_view_sync()
      end)
    end)
  end

  -- Re-fetch discussions from API and re-render the diff view
  local function refresh_discussions()
    local client_mod = require("codereview.api.client")
    local discs = state.provider.get_discussions(client_mod, state.ctx, state.review) or {}
    -- Merge local drafts that the API won't return
    for _, d in ipairs(state.local_drafts or {}) do
      table.insert(discs, d)
    end
    -- Preserve failed optimistic comments; discard still-pending ones
    for _, d in ipairs(state.discussions or {}) do
      if d.is_failed then
        table.insert(discs, d)
      end
    end
    state.discussions = discs
    if state.view_mode == "summary" then
      diff_sidebar.render_summary(layout.main_buf, state)
      diff_sidebar.render_sidebar(layout.sidebar_buf, state)
      return
    end
    diff_state.clear_diff_cache(state)
    rerender_view()
  end

  -- Add a draft comment to local state and re-render
  local function add_local_draft(new_path, new_line, start_line)
    return function(text)
      local disc = {
        notes = {{
          author = "You (draft)",
          body = text,
          created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          position = {
            new_path = new_path,
            new_line = new_line,
            start_line = start_line,
          },
        }},
        is_draft = true,
      }
      if not state.local_drafts then state.local_drafts = {} end
      table.insert(state.local_drafts, disc)
      table.insert(state.discussions, disc)
      rerender_view()
    end
  end

  local function add_optimistic_comment(old_path, new_path, old_line, new_line, start_line)
    return function(text)
      local disc = {
        notes = {{
          author = "You",
          body = text,
          created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          position = {
            old_path = old_path,
            new_path = new_path,
            old_line = old_line,
            new_line = new_line,
            start_line = start_line,
          },
        }},
        is_optimistic = true,
      }
      table.insert(state.discussions, disc)
      rerender_view()
      return disc
    end
  end

  local function add_optimistic_reply(disc)
    return function(text)
      local note = {
        author = "You",
        body = text,
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        is_optimistic = true,
      }
      table.insert(disc.notes, note)
      rerender_view()
      return note
    end
  end

  local function remove_optimistic(disc)
    for i, d in ipairs(state.discussions) do
      if d == disc then
        table.remove(state.discussions, i)
        break
      end
    end
    rerender_view()
  end

  local function remove_optimistic_reply(disc, note)
    for i, n in ipairs(disc.notes) do
      if n == note then
        table.remove(disc.notes, i)
        break
      end
    end
    rerender_view()
  end

  local function mark_optimistic_failed(disc)
    disc.is_optimistic = false
    disc.is_failed = true
    rerender_view()
  end

  local function mark_reply_failed(note)
    note.is_optimistic = false
    note.is_failed = true
    rerender_view()
  end

  -- Re-render current view after AI suggestion state change
  local function rerender_ai()
    if state.scroll_mode then
      local result = diff_render.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
      diff_state.apply_scroll_result(state, result)
    else
      local file = state.files and state.files[state.current_file]
      if not file then return end
      local ld, rd, ra = diff_render.render_file_diff(layout.main_buf, file, state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
      diff_state.apply_file_result(state, state.current_file, ld, rd, ra)
    end
    diff_sidebar.render_sidebar(layout.sidebar_buf, state)
  end

  -- Navigate to next AI suggestion at or after cursor row
  local function nav_to_next_ai(from_row)
    local row_ai_new = state.scroll_mode and state.scroll_row_ai or (state.row_ai_cache[state.current_file] or {})
    local rows = {}
    for r in pairs(row_ai_new) do table.insert(rows, r) end
    table.sort(rows)
    for _, r in ipairs(rows) do
      if r >= from_row then
        vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
        return
      end
    end
    if #rows > 0 then
      vim.api.nvim_win_set_cursor(layout.main_win, { rows[1], 0 })
    end
  end

  -- Get the first discussion at the current cursor line
  local function get_cursor_disc()
    local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
    if state.scroll_mode then
      if state.scroll_row_disc and state.scroll_row_disc[cursor[1]] then
        return state.scroll_row_disc[cursor[1]][1]
      end
    else
      local row_disc = state.row_disc_cache[state.current_file]
      if row_disc and row_disc[cursor[1]] then
        return row_disc[cursor[1]][1]
      end
    end
  end

  local function get_summary_disc()
    if state.view_mode ~= "summary" then return nil end
    local cursor = vim.api.nvim_win_get_cursor(layout.main_win)[1]
    local entry = state.summary_row_map and state.summary_row_map[cursor]
    if entry and (entry.type == "thread" or entry.type == "thread_start") then
      return entry.discussion
    end
  end

  -- Refresh: close and reopen the MR view
  local function refresh()
    require("codereview.review.session").stop()
    local split_mod = require("codereview.ui.split")
    split_mod.close(layout)
    local detail = require("codereview.mr.detail")
    detail.open(state.entry or state.review)
  end

  -- Quit: clean up session and close layout
  local function quit()
    local session = require("codereview.review.session")
    local sess = session.get()
    if sess.ai_pending then
      for _, jid in ipairs(sess.ai_job_ids or {}) do
        pcall(vim.fn.jobstop, jid)
      end
      session.ai_finish()
      vim.notify("AI review cancelled", vim.log.levels.WARN)
    end
    if sess.active then
      session.stop()
      vim.notify("Review session ended — unpublished drafts remain on server", vim.log.levels.WARN)
    end
    active_states[main_buf] = nil
    local split = require("codereview.ui.split")
    split.close(layout)
    pcall(vim.api.nvim_buf_delete, layout.main_buf, { force = true })
  end

  -- ── Main buffer callbacks (all 26 remappable actions) ───────────────────────

  local main_callbacks = {
    next_file = function()
      if state.view_mode ~= "diff" then return end
      if state.scroll_mode then
        local cursor = vim.api.nvim_win_get_cursor(layout.main_win)[1]
        for _, sec in ipairs(state.file_sections) do
          if sec.start_line > cursor then
            vim.api.nvim_win_set_cursor(layout.main_win, { sec.start_line, 0 })
            state.current_file = sec.file_idx
            diff_sidebar.render_sidebar(layout.sidebar_buf, state)
            return
          end
        end
      else
        diff_nav.nav_file(layout, state, 1)
      end
    end,

    prev_file = function()
      if state.view_mode ~= "diff" then return end
      if state.scroll_mode then
        local cursor = vim.api.nvim_win_get_cursor(layout.main_win)[1]
        for i = #state.file_sections, 1, -1 do
          if state.file_sections[i].start_line < cursor then
            vim.api.nvim_win_set_cursor(layout.main_win, { state.file_sections[i].start_line, 0 })
            state.current_file = state.file_sections[i].file_idx
            diff_sidebar.render_sidebar(layout.sidebar_buf, state)
            return
          end
        end
      else
        diff_nav.nav_file(layout, state, -1)
      end
    end,

    -- Comment creation (works in both diff and summary modes)
    -- NOTE: We must NOT map bare "c" with nowait — it blocks cc from ever firing.
    create_comment = function()
      if state.view_mode == "summary" then
        local comment = require("codereview.mr.comment")
        comment.create_mr_comment(state.review, state.provider, state.ctx, refresh_discussions)
        return
      end
      if state.view_mode ~= "diff" then return end
      local session = require("codereview.review.session")
      if state.scroll_mode then
        local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
        local row = cursor[1]
        local data = state.scroll_line_data[row]
        if not data or not data.item then
          vim.notify("No diff line at cursor", vim.log.levels.WARN)
          return
        end
        if data.type == "context" then
          vim.notify("Cannot comment on unchanged lines", vim.log.levels.WARN)
          return
        end
        local file = state.files[data.file_idx]
        local line_text = vim.api.nvim_buf_get_lines(
          vim.api.nvim_win_get_buf(layout.main_win), row - 1, row, false
        )[1] or ""
        local popup_opts = { anchor_line = row, win_id = layout.main_win, action_type = "comment", context_text = line_text }
        local comment = require("codereview.mr.comment")
        if session.get().active then
          local new_path = file.new_path
          local new_line = data.item.new_line
          comment.create_comment(state.review, {
            title = "Draft Comment",
            api_fn = function(provider, client, ctx, mr, text)
              return provider.create_draft_comment(client, ctx, mr, { body = text, path = new_path, line = new_line })
            end,
            on_success = add_local_draft(file.new_path, data.item.new_line),
            success_msg = "Draft comment created",
            failure_msg = "Failed to create draft comment",
            popup_opts = popup_opts,
          })
        else
          local old_path = file.old_path
          local new_path = file.new_path
          local old_line = data.item.old_line
          local new_line = data.item.new_line
          comment.create_comment(state.review, {
            title = "Inline Comment",
            api_fn = function(provider, client, ctx, mr, text)
              return provider.post_comment(client, ctx, mr, text, {
                old_path = old_path,
                new_path = new_path,
                old_line = old_line,
                new_line = new_line,
              })
            end,
            optimistic = {
              add = add_optimistic_comment(old_path, new_path, old_line, new_line),
              remove = remove_optimistic,
              mark_failed = mark_optimistic_failed,
              refresh = refresh_discussions,
            },
            success_msg = "Comment posted",
            failure_msg = "Failed to post comment",
            popup_opts = popup_opts,
          })
        end
      else
        if session.get().active then
          local line_data = state.line_data_cache[state.current_file]
          if not line_data then return end
          local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
          local row = cursor[1]
          local data = line_data[row]
          if not data or not data.item then
            vim.notify("No diff line at cursor", vim.log.levels.WARN)
            return
          end
          if data.type == "context" then
            vim.notify("Cannot comment on unchanged lines", vim.log.levels.WARN)
            return
          end
          local file = state.files[state.current_file]
          local line_text = vim.api.nvim_buf_get_lines(
            vim.api.nvim_win_get_buf(layout.main_win), row - 1, row, false
          )[1] or ""
          local comment = require("codereview.mr.comment")
          local new_path = file.new_path
          local new_line = data.item.new_line
          comment.create_comment(state.review, {
            title = "Draft Comment",
            api_fn = function(provider, client, ctx, mr, text)
              return provider.create_draft_comment(client, ctx, mr, { body = text, path = new_path, line = new_line })
            end,
            on_success = add_local_draft(file.new_path, data.item.new_line),
            success_msg = "Draft comment created",
            failure_msg = "Failed to create draft comment",
            popup_opts = { anchor_line = row, win_id = layout.main_win, action_type = "comment", context_text = line_text },
          })
        else
          diff_comments.create_comment_at_cursor(layout, state, {
            add = add_optimistic_comment,
            remove = remove_optimistic,
            mark_failed = mark_optimistic_failed,
            refresh = refresh_discussions,
          })
        end
      end
    end,

    create_range_comment = function()
      if state.view_mode ~= "diff" then return end
      local session = require("codereview.review.session")
      if state.scroll_mode then
        local s, e = vim.fn.line("v"), vim.fn.line(".")
        if s > e then s, e = e, s end
        local start_data = state.scroll_line_data[s]
        local end_data = state.scroll_line_data[e]
        if not start_data or not start_data.item or not end_data or not end_data.item then
          vim.notify("Invalid selection range", vim.log.levels.WARN)
          return
        end
        if start_data.type == "context" or end_data.type == "context" then
          vim.notify("Cannot comment on unchanged lines", vim.log.levels.WARN)
          return
        end
        local file = state.files[start_data.file_idx]
        local line_text = vim.api.nvim_buf_get_lines(
          vim.api.nvim_win_get_buf(layout.main_win), e - 1, e, false
        )[1] or ""
        local popup_opts = { anchor_line = e, anchor_start = s, win_id = layout.main_win, action_type = "comment", context_text = line_text }
        local comment = require("codereview.mr.comment")
        if session.get().active then
          local new_path = file.new_path
          local end_line = end_data.item.new_line
          comment.create_comment(state.review, {
            title = "Draft Comment",
            api_fn = function(provider, client, ctx, mr, text)
              return provider.create_draft_comment(client, ctx, mr, { body = text, path = new_path, line = end_line })
            end,
            on_success = add_local_draft(file.new_path, end_data.item.new_line, start_data.item.new_line),
            success_msg = "Draft comment created",
            failure_msg = "Failed to create draft comment",
            popup_opts = popup_opts,
          })
        else
          local old_path = file.old_path
          local new_path = file.new_path
          local start_pos = { old_line = start_data.item.old_line, new_line = start_data.item.new_line }
          local end_pos = { old_line = end_data.item.old_line, new_line = end_data.item.new_line }
          comment.create_comment(state.review, {
            title = "Range Comment",
            api_fn = function(provider, client, ctx, mr, text)
              return provider.post_range_comment(client, ctx, mr, text, old_path, new_path, start_pos, end_pos)
            end,
            optimistic = {
              add = add_optimistic_comment(old_path, new_path, end_data.item.old_line, end_data.item.new_line, start_data.item.new_line),
              remove = remove_optimistic,
              mark_failed = mark_optimistic_failed,
              refresh = refresh_discussions,
            },
            success_msg = "Range comment posted",
            failure_msg = "Failed to post range comment",
            popup_opts = popup_opts,
          })
        end
      else
        if session.get().active then
          local line_data = state.line_data_cache[state.current_file]
          if not line_data then return end
          local s, e = vim.fn.line("v"), vim.fn.line(".")
          if s > e then s, e = e, s end
          local start_data = line_data[s]
          local end_data = line_data[e]
          if not start_data or not start_data.item or not end_data or not end_data.item then
            vim.notify("Invalid selection range", vim.log.levels.WARN)
            return
          end
          if start_data.type == "context" or end_data.type == "context" then
            vim.notify("Cannot comment on unchanged lines", vim.log.levels.WARN)
            return
          end
          local file = state.files[state.current_file]
          local line_text = vim.api.nvim_buf_get_lines(
            vim.api.nvim_win_get_buf(layout.main_win), e - 1, e, false
          )[1] or ""
          local comment = require("codereview.mr.comment")
          local new_path = file.new_path
          local end_line = end_data.item.new_line
          comment.create_comment(state.review, {
            title = "Draft Comment",
            api_fn = function(provider, client, ctx, mr, text)
              return provider.create_draft_comment(client, ctx, mr, { body = text, path = new_path, line = end_line })
            end,
            on_success = add_local_draft(file.new_path, end_data.item.new_line, start_data.item.new_line),
            success_msg = "Draft comment created",
            failure_msg = "Failed to create draft comment",
            popup_opts = { anchor_line = e, anchor_start = s, win_id = layout.main_win, action_type = "comment", context_text = line_text },
          })
        else
          diff_comments.create_comment_range(layout, state, {
            add = add_optimistic_comment,
            remove = remove_optimistic,
            mark_failed = mark_optimistic_failed,
            refresh = refresh_discussions,
          })
        end
      end
    end,

    reply = function()
      if state.view_mode == "summary" then
        local disc = get_summary_disc()
        if disc and not disc.is_draft then
          local comment = require("codereview.mr.comment")
          comment.reply(disc, state.review, {
            add_reply = add_optimistic_reply(disc),
            remove_reply = remove_optimistic_reply,
            mark_reply_failed = mark_reply_failed,
            refresh = refresh_discussions,
          }, { anchor_line = vim.api.nvim_win_get_cursor(layout.main_win)[1], win_id = layout.main_win })
        end
        return
      end
      if state.view_mode ~= "diff" then return end
      local disc = get_cursor_disc()
      if disc and not disc.is_draft then
        local comment = require("codereview.mr.comment")
        local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
        -- Find last row belonging to this discussion so float opens below the comment block
        local row_disc = state.scroll_mode and state.scroll_row_disc
          or state.row_disc_cache[state.current_file]
        local last_row = cursor_row
        if row_disc then
          local total = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(layout.main_win))
          for r = cursor_row, math.min(cursor_row + 50, total) do
            local discs = row_disc[r]
            if discs then
              local found = false
              for _, d in ipairs(discs) do
                if d.id == disc.id then found = true; break end
              end
              if found then last_row = r else break end
            else
              break
            end
          end
        end
        -- Calculate how many virtual lines the comment thread occupies
        -- so the reply float can be positioned below them.
        local thread_height = 0
        local notes = disc.notes
        if notes and #notes > 0 then
          thread_height = 1 -- header (┌ @author...)
          thread_height = thread_height + #wrap_text(notes[1].body, config.get().diff.comment_width)
          for i = 2, #notes do
            if not notes[i].system then
              thread_height = thread_height + 1 -- separator (│)
              thread_height = thread_height + 1 -- reply header (│  ↪ @author)
              thread_height = thread_height + #wrap_text(notes[i].body, 58)
            end
          end
          thread_height = thread_height + 1 -- footer (└ r:reply...)
        end
        comment.reply(disc, state.review, {
          add_reply = add_optimistic_reply(disc),
          remove_reply = remove_optimistic_reply,
          mark_reply_failed = mark_reply_failed,
          refresh = refresh_discussions,
        }, { anchor_line = last_row, win_id = layout.main_win, thread_height = thread_height })
      end
    end,

    toggle_resolve = function()
      if state.view_mode == "summary" then
        local disc = get_summary_disc()
        if disc then
          local comment = require("codereview.mr.comment")
          comment.resolve_toggle(disc, state.review, refresh_discussions)
        end
        return
      end
      if state.view_mode ~= "diff" then return end
      local disc = get_cursor_disc()
      if disc then
        local comment = require("codereview.mr.comment")
        comment.resolve_toggle(disc, state.review, refresh_discussions)
      end
    end,

    increase_context = function()
      if state.view_mode ~= "diff" then return end
      diff_nav.adjust_context(layout, state, 1)
    end,

    decrease_context = function()
      if state.view_mode ~= "diff" then return end
      diff_nav.adjust_context(layout, state, -1)
    end,

    toggle_full_file = function()
      if state.view_mode ~= "diff" then return end
      local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      if state.scroll_mode then
        local file_idx = diff_nav.current_file_from_cursor(layout, state)
        local anchor = diff_nav.find_anchor(state.scroll_line_data, cursor_row)
        if state.file_contexts[file_idx] then
          state.file_contexts[file_idx] = nil
        else
          state.file_contexts[file_idx] = 99999
        end
        local result = diff_render.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
        diff_state.apply_scroll_result(state, result)
        local row = diff_nav.find_row_for_anchor(state.scroll_line_data, anchor)
        vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
      else
        local per_file_ld = state.line_data_cache[state.current_file]
        local anchor = diff_nav.find_anchor(per_file_ld or {}, cursor_row, state.current_file)
        if state.context == 99999 then
          state.context = config.get().diff.context
        else
          state.context = 99999
        end
        local file = state.files and state.files[state.current_file]
        if not file then return end
        local ld, rd, ra = diff_render.render_file_diff(layout.main_buf, file, state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
        diff_state.apply_file_result(state, state.current_file, ld, rd, ra)
        local row = diff_nav.find_row_for_anchor(ld, anchor, state.current_file)
        vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
      end
    end,

    toggle_scroll_mode = function()
      if state.view_mode ~= "diff" then return end
      diff_nav.toggle_scroll_mode(layout, state)
    end,

    -- a: approve (summary mode) or accept AI suggestion at cursor (diff mode)
    accept_suggestion = function()
      if state.view_mode == "summary" then
        require("codereview.mr.actions").approve(state.review)
        return
      end
      if state.view_mode ~= "diff" then return end
      local cursor = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local row_ai = state.scroll_mode and state.scroll_row_ai or (state.row_ai_cache[state.current_file] or {})
      local sel = state.row_selection[cursor]
      if not sel or sel.type ~= "ai" then return end
      local ai_idx = sel.index
      local suggestion = row_ai[cursor] and row_ai[cursor][ai_idx]
      if not suggestion then return end

      -- Post as draft comment via API
      local client_mod = require("codereview.api.client")
      local _, post_err = state.provider.create_draft_comment(client_mod, state.ctx, state.review, {
        body = suggestion.comment,
        path = suggestion.file,
        line = suggestion.line,
      })
      if post_err then
        vim.notify("Failed to post draft: " .. post_err, vim.log.levels.ERROR)
        return
      end

      vim.notify("Draft comment posted", vim.log.levels.INFO)
      suggestion.status = "accepted"
      suggestion.drafted = true
      rerender_ai()
      nav_to_next_ai(cursor)
    end,

    -- approve shares default key "a" with accept_suggestion; independent remapping supported
    approve = function()
      if state.view_mode ~= "summary" then return end
      require("codereview.mr.actions").approve(state.review)
    end,

    dismiss_suggestion = function()
      if state.view_mode ~= "diff" then return end
      local cursor = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local row_ai = state.scroll_mode and state.scroll_row_ai or (state.row_ai_cache[state.current_file] or {})
      local sel = state.row_selection[cursor]
      if not sel or sel.type ~= "ai" then return end
      local ai_idx = sel.index
      local suggestion = row_ai[cursor] and row_ai[cursor][ai_idx]
      if not suggestion then return end
      suggestion.status = "dismissed"
      rerender_ai()
      nav_to_next_ai(cursor)
    end,

    edit_suggestion = function()
      if state.view_mode ~= "diff" then return end
      local cursor = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local row_ai = state.scroll_mode and state.scroll_row_ai or (state.row_ai_cache[state.current_file] or {})
      local sel = state.row_selection[cursor]
      if not sel or sel.type ~= "ai" then return end
      local ai_idx = sel.index
      local suggestion = row_ai[cursor] and row_ai[cursor][ai_idx]
      if not suggestion then return end

      -- Hide the suggestion's virt_lines while editing
      vim.api.nvim_buf_clear_namespace(layout.main_buf, AIDRAFT_NS, cursor - 1, cursor)

      local comment = require("codereview.mr.comment")
      comment.open_input_popup("Edit AI Suggestion", function(text)
        suggestion.comment = text

        -- Post edited suggestion as draft comment
        local client_mod = require("codereview.api.client")
        local _, post_err = state.provider.create_draft_comment(client_mod, state.ctx, state.review, {
          body = suggestion.comment,
          path = suggestion.file,
          line = suggestion.line,
        })
        if post_err then
          vim.notify("Failed to post draft: " .. post_err, vim.log.levels.ERROR)
          suggestion.status = "edited"
          rerender_ai()
          return
        end

        vim.notify("Draft comment posted", vim.log.levels.INFO)
        suggestion.status = "accepted"
        suggestion.drafted = true
        rerender_ai()
        nav_to_next_ai(cursor)
      end, {
        action_type = "edit",
        prefill = suggestion.comment,
        anchor_line = cursor,
        win_id = layout.main_win,
        on_close = function() rerender_ai() end,
      })
    end,

    dismiss_all_suggestions = function()
      if state.view_mode ~= "diff" or not state.ai_suggestions then return end
      for _, s in ipairs(state.ai_suggestions) do
        if s.status ~= "accepted" and s.status ~= "edited" then
          s.status = "dismissed"
        end
      end
      rerender_ai()
    end,

    submit = function()
      if state.view_mode ~= "diff" then return end
      local session = require("codereview.review.session")
      local submit_mod = require("codereview.review.submit")

      if session.get().ai_pending then
        vim.notify("AI review still running — publishing available drafts", vim.log.levels.WARN)
      end

      submit_mod.submit_and_publish(state.review, state.ai_suggestions)
      state.local_drafts = {}
      rerender_ai()
      session.stop()
      diff_sidebar.render_sidebar(layout.sidebar_buf, state)
      refresh_discussions()
    end,

    open_in_browser = function()
      if state.view_mode ~= "summary" then return end
      if state.review.web_url then vim.ui.open(state.review.web_url) end
    end,

    merge = function()
      if state.view_mode ~= "summary" then return end
      vim.ui.select({ "Merge", "Merge when pipeline succeeds", "Cancel" }, {
        prompt = string.format("Merge MR #%d?", state.review.id),
      }, function(choice)
        if not choice or choice == "Cancel" then return end
        local ok, actions = pcall(require, "codereview.mr.actions")
        if not ok then
          vim.notify("Merge actions not yet implemented", vim.log.levels.WARN)
          return
        end
        if choice == "Merge when pipeline succeeds" then
          actions.merge(state.review, { auto_merge = true })
        else
          actions.merge(state.review)
        end
      end)
    end,

    show_pipeline = function()
      if state.view_mode ~= "summary" then return end
      vim.notify("Pipeline view (Stage 4)", vim.log.levels.WARN)
    end,

    ai_review = function()
      local session = require("codereview.review.session")
      local s = session.get()
      if s.ai_pending then
        for _, jid in ipairs(s.ai_job_ids or {}) do
          pcall(vim.fn.jobstop, jid)
        end
        session.ai_finish()
        vim.notify("AI review cancelled", vim.log.levels.INFO)
        return
      end
      local review_mod = require("codereview.review")
      review_mod.start(state.review, state, layout)
    end,

    edit_note = function()
      if state.view_mode ~= "diff" then return end
      local disc = get_cursor_disc()
      if not disc then return end
      local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local sel = state.row_selection[cursor_row]
      local sel_idx = sel and sel.type == "comment" and sel.disc_id == disc.id and sel.note_idx or nil
      if not sel_idx then return end  -- no note selected; let edit_suggestion handle "e"
      local note = disc.notes[sel_idx]
      if not note then return end
      if not state.current_user then return end
      if note.author ~= state.current_user then
        vim.notify("Can only edit your own comments", vim.log.levels.WARN)
        return
      end

      -- Compute initial popup height from the prefill line count
      local ifloat = require("codereview.ui.inline_float")
      local init_lines = vim.split(note.body or "", "\n")
      local initial_height = ifloat.compute_height(#init_lines, 0)

      -- Set editing_note state so rerender_view() draws spacer virt_lines
      state.editing_note = {
        disc_id = disc.id,
        note_idx = sel_idx,
        spacer_height = initial_height + 2,
      }
      rerender_view_sync()

      -- Compute spacer_offset: how many virt_lines precede the spacer
      local spacer_offset = tvl.build(disc, {
        sel_idx = sel_idx,
        current_user = state.current_user,
        editing_note = state.editing_note,
        spacer_height = state.editing_note.spacer_height,
        gutter = 4,
      }).spacer_offset

      local comment = require("codereview.mr.comment")
      comment.edit_note(disc, note, state.review, function()
        rerender_view()
      end, {
        win_id = layout.main_win,
        anchor_line = cursor_row,
        spacer_offset = spacer_offset,
        is_reply = sel_idx > 1,
        on_close = function()
          state.editing_note = nil
          rerender_view()
        end,
        on_resize = function(new_h)
          if state.editing_note then
            state.editing_note.spacer_height = new_h + 2
            rerender_view_sync()
          end
        end,
      })
    end,

    delete_note = function()
      if state.view_mode ~= "diff" then return end
      local disc = get_cursor_disc()
      if not disc then return end
      local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local sel = state.row_selection[cursor_row]
      local sel_idx = sel and sel.type == "comment" and sel.disc_id == disc.id and sel.note_idx or nil
      if not sel_idx then return end  -- no note selected; let dismiss_suggestion handle "x"
      local note = disc.notes[sel_idx]
      if not note then return end
      if not state.current_user then return end
      if note.author ~= state.current_user then
        vim.notify("Can only delete your own comments", vim.log.levels.WARN)
        return
      end
      local comment = require("codereview.mr.comment")
      comment.delete_note(disc, note, state.review, function(result)
        state.row_selection[cursor_row] = nil  -- clear selection
        if result and result.removed_disc then
          for i, d in ipairs(state.discussions) do
            if d.id == disc.id then
              table.remove(state.discussions, i)
              break
            end
          end
        end
        rerender_view()
      end)
    end,

    select_next_note = function()
      if state.view_mode ~= "diff" then
        if not state.files or #state.files == 0 then return end
        -- Transition from summary to diff view
        state.view_mode = "diff"
        state.row_selection = {}
        vim.wo[layout.main_win].wrap = false
        vim.wo[layout.main_win].linebreak = false
        if state.scroll_mode then
          local result = diff_render.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user, state.git_diff_cache)
          state.file_sections = result.file_sections
          state.scroll_line_data = result.line_data
          state.scroll_row_disc = result.row_discussions
          state.scroll_row_ai = result.row_ai
          diff_sidebar.render_sidebar(layout.sidebar_buf, state)
        else
          local target = state.current_file or 1
          for idx = 1, #state.files do
            if diff_state.file_has_annotations(state, idx) then
              target = idx
              break
            end
          end
          diff_nav.switch_to_file(layout, state, target)
        end
        vim.api.nvim_win_set_cursor(layout.main_win, { 1, 0 })
        -- Fall through to select first annotation
      end
      local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local row_ai = state.scroll_mode and state.scroll_row_ai or (state.row_ai_cache[state.current_file] or {})
      local row_disc_map = state.scroll_mode and state.scroll_row_disc or (state.row_disc_cache[state.current_file] or {})
      local ai_at_row = row_ai[cursor_row] or {}
      local discs_at_row = row_disc_map[cursor_row] or {}
      local items = diff_comments.build_row_items(ai_at_row, discs_at_row)

      -- Try cycling within current row first
      if #items > 0 then
        local current = state.row_selection[cursor_row]
        local next_sel = diff_comments.cycle_row_selection(items, current, 1)
        if next_sel then
          state.row_selection = { [cursor_row] = next_sel }
          rerender_view()
          return
        end
      end

      -- Past edge (or empty row): jump to next annotated row
      local all_rows = diff_nav.get_annotated_rows(row_disc_map, row_ai)
      for _, r in ipairs(all_rows) do
        if r > cursor_row then
          vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
          diff_nav.ensure_virt_lines_visible(layout.main_win, layout.main_buf, r)
          local next_ai = row_ai[r] or {}
          local next_disc = row_disc_map[r] or {}
          local next_items = diff_comments.build_row_items(next_ai, next_disc)
          state.row_selection = { [r] = next_items[1] or nil }
          rerender_view()
          return
        end
      end

      -- No more rows in current file/buffer
      if state.scroll_mode then
        -- Wrap to first annotated row in scroll buffer
        if #all_rows > 0 then
          local r = all_rows[1]
          vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
          diff_nav.ensure_virt_lines_visible(layout.main_win, layout.main_buf, r)
          local next_ai = row_ai[r] or {}
          local next_disc = row_disc_map[r] or {}
          local next_items = diff_comments.build_row_items(next_ai, next_disc)
          state.row_selection = { [r] = next_items[1] or nil }
          rerender_view()
        end
      else
        -- Per-file mode: try next files, wrapping around
        local files = state.files or {}
        local total = #files
        for offset = 1, total do
          local idx = ((state.current_file - 1 + offset) % total) + 1
          if diff_state.file_has_annotations(state, idx) then
            diff_nav.switch_to_file(layout, state, idx)
            local ra = state.row_ai_cache[idx] or {}
            local rd = state.row_disc_cache[idx] or {}
            local rows = diff_nav.get_annotated_rows(rd, ra)
            if #rows > 0 then
              vim.api.nvim_win_set_cursor(layout.main_win, { rows[1], 0 })
              diff_nav.ensure_virt_lines_visible(layout.main_win, layout.main_buf, rows[1])
              local next_ai = ra[rows[1]] or {}
              local next_disc = rd[rows[1]] or {}
              local next_items = diff_comments.build_row_items(next_ai, next_disc)
              state.row_selection = { [rows[1]] = next_items[1] or nil }
              rerender_view()
            end
            return
          end
        end
      end
    end,

    select_prev_note = function()
      if state.view_mode ~= "diff" then
        if not state.files or #state.files == 0 then return end
        -- Transition from summary to diff view
        state.view_mode = "diff"
        state.row_selection = {}
        vim.wo[layout.main_win].wrap = false
        vim.wo[layout.main_win].linebreak = false
        if state.scroll_mode then
          local result = diff_render.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user, state.git_diff_cache)
          state.file_sections = result.file_sections
          state.scroll_line_data = result.line_data
          state.scroll_row_disc = result.row_discussions
          state.scroll_row_ai = result.row_ai
          diff_sidebar.render_sidebar(layout.sidebar_buf, state)
        else
          local target = state.current_file or 1
          for idx = #state.files, 1, -1 do
            if diff_state.file_has_annotations(state, idx) then
              target = idx
              break
            end
          end
          diff_nav.switch_to_file(layout, state, target)
        end
        local max_line = vim.api.nvim_buf_line_count(layout.main_buf)
        vim.api.nvim_win_set_cursor(layout.main_win, { max_line, 0 })
        -- Fall through to select last annotation
      end
      local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local row_ai = state.scroll_mode and state.scroll_row_ai or (state.row_ai_cache[state.current_file] or {})
      local row_disc_map = state.scroll_mode and state.scroll_row_disc or (state.row_disc_cache[state.current_file] or {})
      local ai_at_row = row_ai[cursor_row] or {}
      local discs_at_row = row_disc_map[cursor_row] or {}
      local items = diff_comments.build_row_items(ai_at_row, discs_at_row)

      -- Try cycling within current row first
      if #items > 0 then
        local current = state.row_selection[cursor_row]
        local next_sel = diff_comments.cycle_row_selection(items, current, -1)
        if next_sel then
          state.row_selection = { [cursor_row] = next_sel }
          rerender_view()
          return
        end
      end

      -- Past edge: jump to prev annotated row
      local all_rows = diff_nav.get_annotated_rows(row_disc_map, row_ai)
      for i = #all_rows, 1, -1 do
        if all_rows[i] < cursor_row then
          local r = all_rows[i]
          vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
          diff_nav.ensure_virt_lines_visible(layout.main_win, layout.main_buf, r)
          local prev_ai = row_ai[r] or {}
          local prev_disc = row_disc_map[r] or {}
          local prev_items = diff_comments.build_row_items(prev_ai, prev_disc)
          state.row_selection = { [r] = prev_items[#prev_items] or nil }
          rerender_view()
          return
        end
      end

      -- No more rows: cross-file backward or wrap
      if state.scroll_mode then
        if #all_rows > 0 then
          local r = all_rows[#all_rows]
          vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
          diff_nav.ensure_virt_lines_visible(layout.main_win, layout.main_buf, r)
          local prev_ai = row_ai[r] or {}
          local prev_disc = row_disc_map[r] or {}
          local prev_items = diff_comments.build_row_items(prev_ai, prev_disc)
          state.row_selection = { [r] = prev_items[#prev_items] or nil }
          rerender_view()
        end
      else
        local files = state.files or {}
        local total = #files
        for offset = 1, total do
          local idx = ((state.current_file - 1 - offset) % total) + 1
          if diff_state.file_has_annotations(state, idx) then
            diff_nav.switch_to_file(layout, state, idx)
            local ra = state.row_ai_cache[idx] or {}
            local rd = state.row_disc_cache[idx] or {}
            local rows = diff_nav.get_annotated_rows(rd, ra)
            if #rows > 0 then
              local r = rows[#rows]
              vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
              diff_nav.ensure_virt_lines_visible(layout.main_win, layout.main_buf, r)
              local prev_ai = ra[r] or {}
              local prev_disc = rd[r] or {}
              local prev_items = diff_comments.build_row_items(prev_ai, prev_disc)
              state.row_selection = { [r] = prev_items[#prev_items] or nil }
              rerender_view()
            end
            return
          end
        end
      end
    end,

    pick_comments = function()
      require("codereview.picker.comments").pick(state, layout)
    end,
    pick_files = function()
      require("codereview.picker.files").pick(state, layout)
    end,
    refresh = refresh,
    quit    = quit,
  }

  km.apply(main_buf, main_callbacks)

  -- ── Sidebar buffer callbacks (subset of actions that apply to sidebar) ───────

  local sidebar_callbacks = {
    next_file = function()
      if state.view_mode ~= "diff" then return end
      diff_nav.nav_file(layout, state, 1)
    end,
    prev_file = function()
      if state.view_mode ~= "diff" then return end
      diff_nav.nav_file(layout, state, -1)
    end,
    toggle_scroll_mode = function()
      if state.view_mode ~= "diff" then return end
      diff_nav.toggle_scroll_mode(layout, state)
    end,
    pick_comments = function()
      require("codereview.picker.comments").pick(state, layout)
    end,
    pick_files = function()
      require("codereview.picker.files").pick(state, layout)
    end,
    refresh = refresh,
    quit    = quit,
  }

  km.apply(sidebar_buf, sidebar_callbacks)

  -- ── Non-registry keymaps ─────────────────────────────────────────────────────

  -- gR: retry a failed optimistic comment
  map(main_buf, "n", "gR", function()
    if state.view_mode ~= "diff" then return end
    local disc = get_cursor_disc()
    if not disc or not disc.is_failed then return end
    disc.is_failed = false
    disc.is_optimistic = true
    rerender_view()
    local note = disc.notes and disc.notes[1]
    if not note then return end
    local provider, _, ctx = require("codereview.providers").detect()
    if not provider then return end
    local client = require("codereview.api.client")
    local comment = require("codereview.mr.comment")
    local pos = note.position or {}
    comment.post_with_retry(
      function() return provider.post_comment(client, ctx, state.review, note.body, pos) end,
      function()
        vim.notify("Comment posted", vim.log.levels.INFO)
        refresh_discussions()
      end,
      function(err)
        vim.notify("Retry failed: " .. err, vim.log.levels.ERROR)
        mark_optimistic_failed(disc)
      end
    )
  end)

  -- D: discard a failed optimistic comment
  map(main_buf, "n", "D", function()
    if state.view_mode ~= "diff" then return end
    local disc = get_cursor_disc()
    if not disc or not disc.is_failed then return end
    remove_optimistic(disc)
    vim.notify("Discarded failed comment", vim.log.levels.INFO)
  end)

  -- Load more context (<CR> on a load_more line)
  map(main_buf, "n", "<CR>", function()
    if state.view_mode ~= "diff" then return end
    local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
    local row = cursor[1]
    local line_data = state.line_data_cache[state.current_file]
    if not line_data or not line_data[row] then return end
    if line_data[row].type == "load_more" then
      diff_nav.adjust_context(layout, state, 10)
    end
  end)

  -- Sidebar: ? to show help
  map(sidebar_buf, "n", "?", function()
    require("codereview.mr.sidebar_help").open()
  end)

  -- Sidebar: <CR> to select file, toggle directory, or open summary
  map(sidebar_buf, "n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(layout.sidebar_win)
    local row = cursor[1]
    local entry = state.sidebar_row_map and state.sidebar_row_map[row]
    if not entry then return end

    -- Restore main_buf into main_win if the user switched to another buffer
    if vim.api.nvim_win_is_valid(layout.main_win)
      and vim.api.nvim_buf_is_valid(layout.main_buf)
      and vim.api.nvim_win_get_buf(layout.main_win) ~= layout.main_buf then
      vim.api.nvim_win_set_buf(layout.main_win, layout.main_buf)
    end

    if entry.type == "summary" then
      state.view_mode = "summary"
      diff_sidebar.render_sidebar(layout.sidebar_buf, state)
      diff_sidebar.render_summary(layout.main_buf, state)
      vim.api.nvim_win_set_cursor(layout.main_win, { 1, 0 })
      vim.api.nvim_set_current_win(layout.main_win)

    elseif entry.type == "dir" then
      if not state.collapsed_dirs then state.collapsed_dirs = {} end
      if state.collapsed_dirs[entry.path] then
        state.collapsed_dirs[entry.path] = nil
      else
        state.collapsed_dirs[entry.path] = true
      end
      diff_sidebar.render_sidebar(layout.sidebar_buf, state)
      pcall(vim.api.nvim_win_set_cursor, layout.sidebar_win, { row, 0 })

    elseif entry.type == "file" then
      -- Lazy load diffs if needed
      if not state.files then
        local provider = state.provider
        local ctx = state.ctx
        if not provider or not ctx then return end
        local client_mod = require("codereview.api.client")
        local files, fetch_err = provider.get_diffs(client_mod, ctx, state.review)
        if fetch_err then
          vim.notify("Failed to fetch diffs: " .. fetch_err, vim.log.levels.ERROR)
          return
        end
        diff_state.load_diffs_into_state(state, files or {})
        diff_sidebar.render_sidebar(layout.sidebar_buf, state)
      end

      state.view_mode = "diff"
      state.current_file = entry.idx
      state.row_selection = {}
      vim.wo[layout.main_win].wrap = false
      vim.wo[layout.main_win].linebreak = false

      if state.scroll_mode then
        -- Always re-render all files (buffer may have summary content)
        local result = diff_render.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
        diff_state.apply_scroll_result(state, result)
        diff_sidebar.render_sidebar(layout.sidebar_buf, state)
        for _, sec in ipairs(state.file_sections) do
          if sec.file_idx == entry.idx then
            vim.api.nvim_win_set_cursor(layout.main_win, { sec.start_line, 0 })
            break
          end
        end
      else
        diff_sidebar.render_sidebar(layout.sidebar_buf, state)
        local line_data, row_disc, row_ai = diff_render.render_file_diff(
          layout.main_buf, state.files[entry.idx], state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
        diff_state.apply_file_result(state, entry.idx, line_data, row_disc, row_ai)
      end
      vim.api.nvim_set_current_win(layout.main_win)
    end
  end)

  -- Restrict sidebar cursor to file/directory rows
  local prev_sb_row = nil
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = sidebar_buf,
    callback = function()
      local ok, cur = pcall(vim.api.nvim_win_get_cursor, layout.sidebar_win)
      if not ok then return end
      local row = cur[1]
      if state.sidebar_row_map[row] then
        prev_sb_row = row
        return
      end
      -- Snap to nearest valid row in direction of movement
      local dir = (prev_sb_row and row > prev_sb_row) and 1 or -1
      local total = vim.api.nvim_buf_line_count(sidebar_buf)
      local target = row + dir
      while target >= 1 and target <= total do
        if state.sidebar_row_map[target] then break end
        target = target + dir
      end
      -- Fallback: try other direction
      if not state.sidebar_row_map[target] then
        target = row - dir
        while target >= 1 and target <= total do
          if state.sidebar_row_map[target] then break end
          target = target - dir
        end
      end
      if state.sidebar_row_map[target] then
        vim.api.nvim_win_set_cursor(layout.sidebar_win, { target, 0 })
        prev_sb_row = target
      end
    end,
  })

  -- Sync sidebar highlight with current file as cursor moves in scroll mode;
  -- also manage row_selection when cursor moves.
  local prev_selection_row = nil
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = main_buf,
    callback = function()
      if state.view_mode ~= "diff" then return end

      local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local row_ai = state.scroll_mode and state.scroll_row_ai or (state.row_ai_cache[state.current_file] or {})
      local ai_at_row = row_ai[cursor_row] or {}
      local row_disc_map = state.scroll_mode and state.scroll_row_disc or (state.row_disc_cache[state.current_file] or {})
      local discs_at_row = row_disc_map[cursor_row] or {}

      local items = diff_comments.build_row_items(ai_at_row, discs_at_row)
      if #items > 0 then
        local prev_sel = state.row_selection[cursor_row]
        if not prev_sel then
          -- Auto-select first item on entering a row with items
          local old_row = prev_selection_row
          state.row_selection = { [cursor_row] = items[1] }
          prev_selection_row = cursor_row
          -- Clear old row's indicator, set new row's indicator
          if old_row and old_row ~= cursor_row then
            diff_render.update_selection_at_row(main_buf, old_row, state.row_selection, row_ai, row_disc_map, state.current_user, state.review, state.editing_note)
          end
          diff_render.update_selection_at_row(main_buf, cursor_row, state.row_selection, row_ai, row_disc_map, state.current_user, state.review, state.editing_note)
        else
          -- Validate prev_sel against current items (may be stale after dismiss/accept)
          local valid = false
          for _, item in ipairs(items) do
            if item.type == prev_sel.type then
              if item.type == "ai" and item.index == prev_sel.index then
                valid = true; break
              end
              if item.type == "comment" and item.disc_id == prev_sel.disc_id
                  and item.note_idx == prev_sel.note_idx then
                valid = true; break
              end
            end
          end
          if not valid then
            -- Data changed (item dismissed/accepted): full rerender
            state.row_selection = { [cursor_row] = items[1] }
            prev_selection_row = cursor_row
            rerender_view()
          elseif next(state.row_selection, next(state.row_selection)) or not state.row_selection[cursor_row] then
            -- Clear selections on other rows — purely cosmetic
            local old_row = prev_selection_row
            state.row_selection = { [cursor_row] = state.row_selection[cursor_row] }
            prev_selection_row = cursor_row
            if old_row and old_row ~= cursor_row then
              diff_render.update_selection_at_row(main_buf, old_row, state.row_selection, row_ai, row_disc_map, state.current_user, state.review, state.editing_note)
            end
            diff_render.update_selection_at_row(main_buf, cursor_row, state.row_selection, row_ai, row_disc_map, state.current_user, state.review, state.editing_note)
          else
            prev_selection_row = cursor_row
          end
        end
      else
        local had = next(state.row_selection) ~= nil
        local old_row = prev_selection_row
        state.row_selection = {}
        prev_selection_row = nil
        if had then
          -- Clear old row's indicator only
          if old_row then
            diff_render.update_selection_at_row(main_buf, old_row, state.row_selection, row_ai, row_disc_map, state.current_user, state.review, state.editing_note)
          end
        end
      end

      -- Sync sidebar file highlight in scroll mode
      if state.scroll_mode and #state.file_sections > 0 then
        local file_idx = diff_nav.current_file_from_cursor(layout, state)
        if file_idx ~= state.current_file then
          state.current_file = file_idx
          diff_sidebar.render_sidebar(layout.sidebar_buf, state)
        end
      end

      -- Review tracking: mark visible hunks as seen, re-render sidebar on change
      local track_idx = state.current_file or 1
      local file_entry = state.files and state.files[track_idx]
      local track_path = file_entry and (file_entry.new_path or file_entry.old_path)
      if track_path then
        local line_data = state.scroll_mode
          and state.scroll_line_data
          or (state.line_data_cache[track_idx] or {})
        if #line_data > 0 then
          if not state.file_review_status[track_path] then
            state.file_review_status[track_path] = tracker.init_file(
              track_path, line_data,
              state.scroll_mode and track_idx or nil
            )
          end
          local frs = state.file_review_status[track_path]
          local ok, w0 = pcall(vim.fn.line, "w0")
          if ok then
            local win_height = vim.api.nvim_win_get_height(layout.main_win)
            local changed = tracker.mark_visible(frs, w0, w0 + win_height - 1)
            if changed then
              diff_sidebar.render_sidebar(layout.sidebar_buf, state)
            end
          end
        end
      end
    end,
  })
end

return M
