-- lua/codereview/mr/diff_sidebar.lua
-- Sidebar and summary rendering for the diff viewer.
-- Handles the file-list sidebar, session stats, and MR summary view.

local M = {}
local diff_render = require("codereview.mr.diff_render")

-- Helpers pulled from diff_render (sidebar uses these directly)
local apply_line_hl = diff_render.apply_line_hl
local apply_word_hl = diff_render.apply_word_hl
local discussion_matches_file = diff_render.discussion_matches_file

-- nvim_create_namespace returns the same ID for the same name — safe to declare
-- in multiple modules.
local DIFF_NS = vim.api.nvim_create_namespace("codereview_diff")
local SUMMARY_NS = vim.api.nvim_create_namespace("codereview_summary")

-- ─── Counting helpers ─────────────────────────────────────────────────────────

local function count_file_comments(file, discussions)
  local n = 0
  for _, disc in ipairs(discussions or {}) do
    if discussion_matches_file(disc, file) then n = n + 1 end
  end
  return n
end

local function count_file_unresolved(file, discussions)
  local n = 0
  for _, disc in ipairs(discussions or {}) do
    if discussion_matches_file(disc, file) and not disc.local_draft and not disc.resolved then
      n = n + 1
    end
  end
  return n
end

local function count_file_ai(file, suggestions)
  local n = 0
  local path = file.new_path or file.old_path
  for _, s in ipairs(suggestions or {}) do
    if s.file == path and s.status ~= "dismissed" then n = n + 1 end
  end
  return n
end

local function count_session_stats(state)
  local stats = { drafts = 0, ai_accepted = 0, ai_dismissed = 0, ai_pending = 0, threads = 0, unresolved = 0 }
  for _ in ipairs(state.local_drafts or {}) do
    stats.drafts = stats.drafts + 1
  end
  for _, s in ipairs(state.ai_suggestions or {}) do
    if s.status == "accepted" or s.status == "edited" then
      stats.ai_accepted = stats.ai_accepted + 1
    elseif s.status == "dismissed" then
      stats.ai_dismissed = stats.ai_dismissed + 1
    elseif s.status == "pending" then
      stats.ai_pending = stats.ai_pending + 1
    end
  end
  for _, d in ipairs(state.discussions or {}) do
    if not d.local_draft then
      stats.threads = stats.threads + 1
      if not d.resolved then
        stats.unresolved = stats.unresolved + 1
      end
    end
  end
  return stats
end

-- ─── Footer builder ───────────────────────────────────────────────────────────

--- Build dynamic keymap footer lines + highlight metadata.
--- @param state table  diff viewer state
--- @param sess table   current review session (from session.get())
--- @return string[] lines
--- @return table[] highlights  Array of {row:integer, line_hl:string}
local function build_footer(state, sess)
  local km = require("codereview.keymaps")
  local lines = {}
  local hls = {}

  -- Returns the display string for an action key, or nil if disabled.
  -- Converts Vim notation: <C-f> → ⌃F
  local function k(action)
    local key = km.get(action)
    if not key or key == false then return nil end
    return (key
      :gsub("<C%-(%a)>", function(c) return "⌃" .. c:upper() end)
      :gsub("<S%-Tab>", "S-Tab")
      :gsub("<Tab>", "Tab"))
  end

  local function header(label)
    local text = string.format("───── %s %s", label, string.rep("─", 24 - #label))
    table.insert(lines, text)
    hls[#hls + 1] = { row = #lines, line_hl = "CodeReviewHidden" }
  end

  local function row(text)
    table.insert(lines, text)
  end

  -- Build a two-item display line; omits item if key is nil
  local function pair_row(k1, label1, sep, k2, label2)
    if k1 and k2 then
      row(k1 .. " " .. label1 .. sep .. k2 .. " " .. label2)
    elseif k1 then
      row(k1 .. " " .. label1)
    elseif k2 then
      row(k2 .. " " .. label2)
    end
  end

  table.insert(lines, "")
  table.insert(lines, string.rep("─", 30))

  if state.view_mode == "summary" then
    header("Comment")
    local r_key = k("reply")
    if r_key then row(r_key .. " reply") end
    local resolve_key = k("toggle_resolve")
    if resolve_key then row(resolve_key .. "     resolve") end

    header("Actions")
    pair_row(k("approve"), "approve", "   ", k("open_in_browser"), "open")
    pair_row(k("merge"), "merge", "     ", k("refresh"), "refresh")
    if k("quit") then row(k("quit") .. " quit") end
    return lines, hls
  end

  -- Diff mode

  header("Navigate")
  local nf, pf = k("next_file"), k("prev_file")
  if nf and pf then row(nf .. " " .. pf .. "  files")
  elseif nf then row(nf .. "  next file")
  elseif pf then row(pf .. "  prev file")
  end
  local nn, pn = k("select_next_note"), k("select_prev_note")
  if nn and pn then row(nn .. " " .. pn .. "  notes")
  elseif nn then row(nn .. "  next note")
  elseif pn then row(pn .. "  prev note")
  end

  header("Comment")
  local cc_key, r_key = k("create_comment"), k("reply")
  if cc_key and r_key then row(cc_key .. "     new       " .. r_key .. " reply")
  elseif cc_key then row(cc_key .. "  new comment")
  elseif r_key then row(r_key .. " reply")
  end
  local resolve_key = k("toggle_resolve")
  if resolve_key then row(resolve_key .. "     resolve") end

  if sess.active then
    header("Review")
    pair_row(k("accept_suggestion"), "accept", "   ", k("dismiss_suggestion"), "dismiss")
    pair_row(k("edit_suggestion"), "edit", "     ", k("dismiss_all_suggestions"), "dismiss all")
    pair_row(k("submit"), "submit", "   ", k("ai_review"), "cancel AI")
  end

  header("View")
  pair_row(k("toggle_full_file"), "full", "      ", k("toggle_scroll_mode"), "scroll")
  pair_row(k("refresh"), "refresh", "   ", k("quit"), "quit")

  return lines, hls
end

-- ─── Sidebar rendering ────────────────────────────────────────────────────────

function M.render_sidebar(buf, state)
  local list = require("codereview.mr.list")
  local review = state.review
  local files = state.files or {}

  local lines = {}

  -- Review header
  table.insert(lines, string.format("#%d", review.id or 0))
  table.insert(lines, (review.title or ""):sub(1, 28))
  table.insert(lines, list.pipeline_icon(review.pipeline_status) .. " " .. (review.source_branch or ""))
  table.insert(lines, string.rep("─", 30))
  local session = require("codereview.review.session")
  local sess = session.get()
  local stats = count_session_stats(state)
  local status_start_row = #lines  -- track where status lines begin for highlights

  state.sidebar_status_row = nil
  state.sidebar_drafts_row = nil
  state.sidebar_threads_row = nil

  if sess.active then
    if sess.ai_pending then
      if sess.ai_total > 0 and sess.ai_completed > 0 then
        table.insert(lines, string.format("⟳ AI reviewing… %d/%d", sess.ai_completed, sess.ai_total))
      else
        table.insert(lines, "⟳ AI reviewing…")
      end
    else
      table.insert(lines, "● Review in progress")
    end
    state.sidebar_status_row = #lines
  end

  -- Drafts + AI stats line
  if sess.active then
    local parts = {}
    if stats.drafts > 0 then
      table.insert(parts, string.format("✎ %d drafts", stats.drafts))
    end
    if state.ai_suggestions then
      local ai_parts = {}
      if stats.ai_accepted > 0 then table.insert(ai_parts, "✓" .. stats.ai_accepted) end
      if stats.ai_dismissed > 0 then table.insert(ai_parts, "✗" .. stats.ai_dismissed) end
      if stats.ai_pending > 0 then table.insert(ai_parts, "⏳" .. stats.ai_pending) end
      if #ai_parts > 0 then
        table.insert(parts, table.concat(ai_parts, " ") .. " AI")
      end
    end
    if #parts > 0 then
      table.insert(lines, table.concat(parts, "  "))
      state.sidebar_drafts_row = #lines
    end
  end

  -- Threads line (always when discussions exist)
  if stats.threads > 0 then
    local tline = string.format("💬 %d threads", stats.threads)
    if stats.unresolved > 0 then
      tline = tline .. string.format("  ⚠ %d open", stats.unresolved)
    end
    table.insert(lines, tline)
    state.sidebar_threads_row = #lines
  end

  if #lines > status_start_row then
    table.insert(lines, "")
  end
  table.insert(lines, string.format("%d files changed", #files))
  local mode_str = state.scroll_mode and "All files" or "Per file"
  table.insert(lines, mode_str)
  table.insert(lines, "")

  -- Build directory grouping (preserving original order)
  local dirs_order = {}
  local dirs = {}
  local root_files = {}

  for i, file in ipairs(files) do
    local path = file.new_path or file.old_path or "unknown"
    local dir = vim.fn.fnamemodify(path, ":h")
    local name = vim.fn.fnamemodify(path, ":t")
    if dir == "." or dir == "" then
      table.insert(root_files, { idx = i, name = name })
    else
      if not dirs[dir] then
        dirs[dir] = {}
        table.insert(dirs_order, dir)
      end
      table.insert(dirs[dir], { idx = i, name = name })
    end
  end

  state.sidebar_row_map = {}

  -- Summary button
  local summary_indicator = (state.view_mode == "summary") and "▸" or " "
  table.insert(lines, string.format("%s ℹ Summary", summary_indicator))
  state.sidebar_row_map[#lines] = { type = "summary" }
  table.insert(lines, "")

  -- Render directories
  for _, dir in ipairs(dirs_order) do
    local collapsed = state.collapsed_dirs and state.collapsed_dirs[dir]
    local icon = collapsed and "▸" or "▾"
    local dir_display = dir
    if #dir_display > 24 then
      dir_display = ".." .. dir_display:sub(-22)
    end
    table.insert(lines, string.format("%s %s/", icon, dir_display))
    state.sidebar_row_map[#lines] = { type = "dir", path = dir }

    if not collapsed then
      for _, entry in ipairs(dirs[dir]) do
        local indicator = (state.view_mode == "diff" and entry.idx == state.current_file) and "▸" or " "
        local ccount = count_file_comments(files[entry.idx], state.discussions)
        local cstr = ccount > 0 and (" [" .. ccount .. "]") or ""
        local aicount = count_file_ai(files[entry.idx], state.ai_suggestions)
        local aistr = aicount > 0 and (" 🤖" .. aicount) or ""
        local ucount = count_file_unresolved(files[entry.idx], state.discussions)
        local ustr = ucount > 0 and (" ⚠" .. ucount) or ""
        local name = entry.name
        local max_name = 22 - #cstr - #aistr - #ustr
        if #name > max_name then name = ".." .. name:sub(-(max_name - 2)) end
        table.insert(lines, string.format("  %s %s%s%s%s", indicator, name, cstr, aistr, ustr))
        state.sidebar_row_map[#lines] = { type = "file", idx = entry.idx }
      end
    end
  end

  -- Root-level files
  for _, entry in ipairs(root_files) do
    local indicator = (state.view_mode == "diff" and entry.idx == state.current_file) and "▸" or " "
    local ccount = count_file_comments(files[entry.idx], state.discussions)
    local cstr = ccount > 0 and (" [" .. ccount .. "]") or ""
    local aicount = count_file_ai(files[entry.idx], state.ai_suggestions)
    local aistr = aicount > 0 and (" 🤖" .. aicount) or ""
    local ucount = count_file_unresolved(files[entry.idx], state.discussions)
    local ustr = ucount > 0 and (" ⚠" .. ucount) or ""
    local name = entry.name
    local max_name = 24 - #cstr - #aistr - #ustr
    if #name > max_name then name = ".." .. name:sub(-(max_name - 2)) end
    table.insert(lines, string.format("  %s %s%s%s%s", indicator, name, cstr, aistr, ustr))
    state.sidebar_row_map[#lines] = { type = "file", idx = entry.idx }
  end

  local footer_lines, footer_hls = build_footer(state, sess)
  local footer_start = #lines
  for _, fl in ipairs(footer_lines) do
    table.insert(lines, fl)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Highlight summary button, current file + directory headers
  vim.api.nvim_buf_clear_namespace(buf, DIFF_NS, 0, -1)
  for row, entry in pairs(state.sidebar_row_map) do
    if entry.type == "summary" then
      pcall(apply_line_hl, buf, row - 1, "CodeReviewSummaryButton")
    elseif entry.type == "file" and state.view_mode == "diff" and entry.idx == state.current_file then
      pcall(apply_line_hl, buf, row - 1, "CodeReviewFileChanged")
    elseif entry.type == "dir" then
      pcall(apply_line_hl, buf, row - 1, "CodeReviewHidden")
    end
    if entry.type == "file" then
      local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
      local file_segments = {
        { pat = "🤖%d+", hl = "CodeReviewAIDraft" },
        { pat = "⚠%d+", hl = "CodeReviewCommentUnresolved" },
      }
      for _, seg in ipairs(file_segments) do
        local s, e = string.find(line, seg.pat)
        if s then
          pcall(apply_word_hl, buf, row - 1, s - 1, e, seg.hl)
        end
      end
    end
  end

  -- Status line highlights
  if state.sidebar_status_row then
    local hl = sess.ai_pending and "CodeReviewSpinner" or "CodeReviewFileAdded"
    pcall(apply_line_hl, buf, state.sidebar_status_row - 1, hl)
  end
  if state.sidebar_threads_row and stats.unresolved > 0 then
    pcall(apply_line_hl, buf, state.sidebar_threads_row - 1, "CodeReviewCommentUnresolved")
  end

  -- Per-segment highlights on drafts+AI line
  if state.sidebar_drafts_row then
    local row0 = state.sidebar_drafts_row - 1
    local line = vim.api.nvim_buf_get_lines(buf, row0, row0 + 1, false)[1] or ""
    local segments = {
      { pat = "✓%d+", hl = "CodeReviewFileAdded" },
      { pat = "✗%d+", hl = "CodeReviewFileDeleted" },
      { pat = "⏳%d+", hl = "CodeReviewHidden" },
    }
    for _, seg in ipairs(segments) do
      local s, e = string.find(line, seg.pat)
      if s then
        pcall(apply_word_hl, buf, row0, s - 1, e, seg.hl)
      end
    end
  end

  -- Footer group header highlights
  for _, fhl in ipairs(footer_hls) do
    pcall(apply_line_hl, buf, footer_start + fhl.row - 1, fhl.line_hl)
  end
end

-- ─── Summary rendering ────────────────────────────────────────────────────────

function M.render_summary(buf, state)
  vim.schedule(function()
    local split = require("codereview.ui.split")
    if split.saved_visual then
      vim.api.nvim_set_hl(0, "Visual", split.saved_visual)
    end
  end)
  local detail = require("codereview.mr.detail")
  local win_width = (state.layout and state.layout.main_win)
    and vim.api.nvim_win_get_width(state.layout.main_win)
    or tonumber(vim.o.columns) or 80
  local pane_width = math.floor(win_width * 0.8)

  local header = detail.build_header_lines(state.review, pane_width)
  local lines = {}
  for _, l in ipairs(header.lines) do table.insert(lines, l) end

  local activity = detail.build_activity_lines(state.discussions, pane_width)
  for _, line in ipairs(activity.lines) do
    table.insert(lines, line)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Clear old summary highlights
  vim.api.nvim_buf_clear_namespace(buf, SUMMARY_NS, 0, -1)

  local header_count = #header.lines

  -- Apply header (description) highlights
  for _, hl in ipairs(header.highlights) do
    pcall(vim.api.nvim_buf_set_extmark, buf, SUMMARY_NS, hl[1], hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
  end

  -- Activity lines start after header
  for _, hl in ipairs(activity.highlights) do
    local row = header_count + hl[1]  -- 0-indexed row in buffer
    pcall(vim.api.nvim_buf_set_extmark, buf, SUMMARY_NS, row, hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
  end

  -- Apply treesitter syntax highlighting to code blocks
  local all_code_blocks = {}
  if header.code_blocks then
    for _, cb in ipairs(header.code_blocks) do
      table.insert(all_code_blocks, cb)
    end
  end
  if activity.code_blocks then
    for _, cb in ipairs(activity.code_blocks) do
      table.insert(all_code_blocks, {
        start_row = header_count + cb.start_row,
        end_row = header_count + cb.end_row,
        lang = cb.lang,
        text = cb.text,
        indent = cb.indent,
      })
    end
  end

  for _, cb in ipairs(all_code_blocks) do
    if cb.lang and cb.lang ~= "" then
      local ok, parser = pcall(vim.treesitter.get_string_parser, cb.text, cb.lang)
      if ok and parser then
        local trees = parser:parse()
        if trees and trees[1] then
          local root = trees[1]:root()
          local query_ok, query = pcall(vim.treesitter.query.get, cb.lang, "highlights")
          if query_ok and query then
            for id, node in query:iter_captures(root, cb.text, 0, -1) do
              local name = query.captures[id]
              local sr, sc, er, ec = node:range()
              pcall(vim.api.nvim_buf_set_extmark, buf, SUMMARY_NS,
                cb.start_row + sr, sc + cb.indent,
                { end_row = cb.start_row + er, end_col = ec + cb.indent, hl_group = "@" .. name })
            end
          end
        end
      end
    end
  end

  -- Build summary row map (buffer row -> discussion)
  state.summary_row_map = {}
  for offset, entry in pairs(activity.row_map) do
    state.summary_row_map[header_count + offset + 1] = entry  -- +1 for 1-indexed rows
  end

  vim.bo[buf].modifiable = false

  -- Enable soft wrap for long lines
  if state.layout and state.layout.main_win then
    vim.wo[state.layout.main_win].wrap = true
    vim.wo[state.layout.main_win].linebreak = true
  end
end

return M
