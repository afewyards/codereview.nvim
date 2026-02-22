local M = {}

-- LINE_NR_WIDTH: "%5d | %-5d " = 5+3+5+1 = 14 chars
local LINE_NR_WIDTH = 14
M.LINE_NR_WIDTH = LINE_NR_WIDTH

local DIFF_NS = vim.api.nvim_create_namespace("glab_review_diff")

-- ─── Formatting helpers ───────────────────────────────────────────────────────

function M.format_line_number(old_nr, new_nr)
  local old_str = old_nr and string.format("%5d", old_nr) or "     "
  local new_str = new_nr and string.format("%-5d", new_nr) or "     "
  return old_str .. " | " .. new_str .. " "
end

function M.format_hidden_line(count)
  return string.format("... %d lines hidden (press <CR> to expand) ...", count)
end

-- ─── Highlight application ────────────────────────────────────────────────────

local function apply_line_hl(buf, row, hl_group)
  vim.api.nvim_buf_set_extmark(buf, DIFF_NS, row, 0, { line_hl_group = hl_group })
end

local function apply_word_hl(buf, row, col_start, col_end, hl_group)
  if col_start >= col_end then return end
  vim.api.nvim_buf_set_extmark(buf, DIFF_NS, row, col_start, {
    end_col = col_end,
    hl_group = hl_group,
  })
end

-- ─── Sign helpers ─────────────────────────────────────────────────────────────

local function discussion_matches_file(discussion, file_diff)
  local note = discussion.notes and discussion.notes[1]
  if not note or not note.position then return false end
  local pos = note.position
  local path = pos.new_path or pos.old_path
  return path == file_diff.new_path or path == file_diff.old_path
end

local function discussion_line(discussion)
  local note = discussion.notes and discussion.notes[1]
  if not note or not note.position then return nil end
  local pos = note.position
  return pos.new_line or pos.old_line
end

local function is_resolved(discussion)
  if discussion.resolved ~= nil then return discussion.resolved end
  local note = discussion.notes and discussion.notes[1]
  return note and note.resolved
end

function M.place_comment_signs(buf, line_data, discussions, file_diff)
  -- Remove old signs for this buffer
  pcall(vim.fn.sign_unplace, "GlabReview", { buffer = buf })

  for _, discussion in ipairs(discussions or {}) do
    if discussion_matches_file(discussion, file_diff) then
      local target_line = discussion_line(discussion)
      if target_line then
        -- Find the buffer row matching this line number
        for row, data in ipairs(line_data) do
          local item = data.item
          if item and (item.new_line == target_line or item.old_line == target_line) then
            local sign_name = is_resolved(discussion) and "GlabReviewCommentSign"
              or "GlabReviewUnresolvedSign"
            pcall(vim.fn.sign_place, 0, "GlabReview", sign_name, buf, { lnum = row })
            break
          end
        end
      end
    end
  end
end

-- ─── Diff rendering ───────────────────────────────────────────────────────────

function M.render_file_diff(buf, file_diff, mr, discussions)
  local parser = require("glab_review.mr.diff_parser")
  local config = require("glab_review.config")
  local context = config.get().diff.context

  -- Try local git diff with more context lines; fall back to API diff
  local diff_text = file_diff.diff or ""
  if mr.diff_refs and mr.diff_refs.base_sha and mr.diff_refs.head_sha then
    local path = file_diff.new_path or file_diff.old_path
    if path then
      local result = vim.fn.system({
        "git", "diff",
        "-U" .. context,
        mr.diff_refs.base_sha,
        mr.diff_refs.head_sha,
        "--", path,
      })
      if vim.v.shell_error == 0 and result ~= "" then
        diff_text = result
      end
    end
  end

  local hunks = parser.parse_hunks(diff_text)
  local display = parser.build_display(hunks, context)

  local lines = {}
  local line_data = {}

  for _, item in ipairs(display) do
    if item.type == "hidden" then
      table.insert(lines, M.format_hidden_line(item.count))
      table.insert(line_data, { type = "hidden", item = item })
    else
      local prefix = M.format_line_number(item.old_line, item.new_line)
      table.insert(lines, prefix .. (item.text or ""))
      table.insert(line_data, { type = item.type, item = item })
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Set syntax from file extension for code highlighting
  local path = file_diff.new_path or file_diff.old_path or ""
  local ft = vim.filetype.match({ filename = path })
  if ft then
    vim.bo[buf].syntax = ft
  end

  -- Clear previous highlights
  vim.api.nvim_buf_clear_namespace(buf, DIFF_NS, 0, -1)

  -- Apply line-level highlights and collect word-diff candidates
  local prev_delete_row = nil
  local prev_delete_text = nil

  for i, data in ipairs(line_data) do
    local row = i - 1
    if data.type == "add" then
      apply_line_hl(buf, row, "GlabReviewDiffAdd")
      -- Word diff against previous delete if adjacent
      if prev_delete_row == row - 1 and prev_delete_text then
        local segments = parser.word_diff(prev_delete_text, data.item.text or "")
        for _, seg in ipairs(segments) do
          apply_word_hl(buf, prev_delete_row,
            LINE_NR_WIDTH + seg.old_start, LINE_NR_WIDTH + seg.old_end,
            "GlabReviewDiffDeleteWord")
          apply_word_hl(buf, row,
            LINE_NR_WIDTH + seg.new_start, LINE_NR_WIDTH + seg.new_end,
            "GlabReviewDiffAddWord")
        end
      end
      prev_delete_row = nil
      prev_delete_text = nil
    elseif data.type == "delete" then
      apply_line_hl(buf, row, "GlabReviewDiffDelete")
      prev_delete_row = row
      prev_delete_text = data.item.text or ""
    elseif data.type == "hidden" then
      apply_line_hl(buf, row, "GlabReviewHidden")
      prev_delete_row = nil
      prev_delete_text = nil
    else
      prev_delete_row = nil
      prev_delete_text = nil
    end
  end

  if discussions then
    M.place_comment_signs(buf, line_data, discussions, file_diff)
  end

  return line_data
end

-- ─── Sidebar rendering ────────────────────────────────────────────────────────

function M.render_sidebar(buf, state)
  local list = require("glab_review.mr.list")
  local mr = state.mr
  local files = state.files or {}

  local lines = {}

  -- MR header
  table.insert(lines, string.format("MR !%d", mr.iid or 0))
  table.insert(lines, (mr.title or ""):sub(1, 28))
  local pipeline_status = mr.head_pipeline and mr.head_pipeline.status or nil
  table.insert(lines, list.pipeline_icon(pipeline_status) .. " " .. (mr.source_branch or ""))
  table.insert(lines, string.rep("─", 30))
  table.insert(lines, string.format("%d files changed", #files))
  table.insert(lines, "")

  -- File list
  for i, file in ipairs(files) do
    local indicator = (i == state.current_file) and ">" or " "
    local path = file.new_path or file.old_path or "unknown"
    -- Count discussions for this file
    local comment_count = 0
    for _, disc in ipairs(state.discussions or {}) do
      if discussion_matches_file(disc, file) then
        comment_count = comment_count + 1
      end
    end
    local comment_str = comment_count > 0 and (" [" .. comment_count .. "]") or ""
    -- Truncate path to fit sidebar
    local max_path = 26 - #comment_str
    if #path > max_path then
      path = ".." .. path:sub(-(max_path - 2))
    end
    table.insert(lines, string.format("%s %s%s", indicator, path, comment_str))
  end

  table.insert(lines, "")
  table.insert(lines, string.rep("─", 30))
  table.insert(lines, "]f/[f files  ]c/[c cmts")
  table.insert(lines, "cc:comment  R:refresh  q:quit")

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Highlight current file line
  local file_start_row = 6  -- 0-indexed: header takes rows 0-5
  local current_row = file_start_row + (state.current_file - 1)
  vim.api.nvim_buf_clear_namespace(buf, DIFF_NS, 0, -1)
  pcall(apply_line_hl, buf, current_row, "GlabReviewFileChanged")
end

-- ─── Expand hidden ────────────────────────────────────────────────────────────

function M.expand_hidden(layout, state)
  local main_buf = layout.main_buf
  local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
  local row = cursor[1]  -- 1-indexed

  -- Re-render current file without context collapsing (show all lines)
  local file = state.files and state.files[state.current_file]
  if not file then return end

  -- Re-parse with full context from local git if available
  local parser = require("glab_review.mr.diff_parser")
  local diff_text = file.diff or ""
  if state.mr.diff_refs and state.mr.diff_refs.base_sha and state.mr.diff_refs.head_sha then
    local path = file.new_path or file.old_path
    if path then
      local result = vim.fn.system({
        "git", "diff",
        "-U99999",
        state.mr.diff_refs.base_sha,
        state.mr.diff_refs.head_sha,
        "--", path,
      })
      if vim.v.shell_error == 0 and result ~= "" then
        diff_text = result
      end
    end
  end
  local hunks = parser.parse_hunks(diff_text)
  local display = parser.build_display(hunks, 99999)

  local lines = {}
  local line_data = {}
  for _, item in ipairs(display) do
    local prefix = M.format_line_number(item.old_line, item.new_line)
    table.insert(lines, prefix .. (item.text or ""))
    table.insert(line_data, { type = item.type, item = item })
  end

  vim.bo[main_buf].modifiable = true
  vim.api.nvim_buf_set_lines(main_buf, 0, -1, false, lines)
  vim.bo[main_buf].modifiable = false
  state.line_data_cache[state.current_file] = line_data

  -- Re-apply highlights
  vim.api.nvim_buf_clear_namespace(main_buf, DIFF_NS, 0, -1)
  for i, data in ipairs(line_data) do
    local r = i - 1
    if data.type == "add" then
      apply_line_hl(main_buf, r, "GlabReviewDiffAdd")
    elseif data.type == "delete" then
      apply_line_hl(main_buf, r, "GlabReviewDiffDelete")
    end
  end

  M.place_comment_signs(main_buf, line_data, state.discussions, file)
  vim.api.nvim_win_set_cursor(layout.main_win, { math.min(row, #lines), 0 })
end

-- ─── Comment creation ─────────────────────────────────────────────────────────

function M.create_comment_at_cursor(layout, state)
  local line_data = state.line_data_cache[state.current_file]
  if not line_data then return end
  local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
  local row = cursor[1]
  local data = line_data[row]
  if not data or not data.item then
    vim.notify("No diff line at cursor", vim.log.levels.WARN)
    return
  end
  local file = state.files[state.current_file]
  local comment = require("glab_review.mr.comment")
  comment.create_inline(
    state.mr,
    file.old_path,
    file.new_path,
    data.item.old_line,
    data.item.new_line
  )
end

function M.create_comment_range(layout, state)
  local line_data = state.line_data_cache[state.current_file]
  if not line_data then return end
  -- Get visual selection range
  local start_row = vim.fn.line("'<")
  local end_row = vim.fn.line("'>")
  local start_data = line_data[start_row]
  local end_data = line_data[end_row]
  if not start_data or not end_data then
    vim.notify("Invalid selection range", vim.log.levels.WARN)
    return
  end
  local file = state.files[state.current_file]
  local comment = require("glab_review.mr.comment")
  comment.create_inline_range(
    state.mr,
    file.old_path,
    file.new_path,
    { old_line = start_data.item.old_line, new_line = start_data.item.new_line },
    { old_line = end_data.item.old_line, new_line = end_data.item.new_line }
  )
end

-- ─── Navigation helpers ───────────────────────────────────────────────────────

local function nav_file(layout, state, delta)
  local files = state.files or {}
  local next_idx = state.current_file + delta
  if next_idx < 1 or next_idx > #files then return end
  state.current_file = next_idx
  M.render_sidebar(layout.sidebar_buf, state)
  local line_data = M.render_file_diff(layout.main_buf, files[next_idx], state.mr, state.discussions)
  state.line_data_cache[next_idx] = line_data
  vim.api.nvim_win_set_cursor(layout.main_win, { 1, 0 })
end

local function nav_comment(layout, state, delta)
  local line_data = state.line_data_cache[state.current_file]
  if not line_data then return end
  local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
  local current_row = cursor[1]
  local comment_rows = {}
  for i, data in ipairs(line_data) do
    if data.type == "add" or data.type == "delete" or data.type == "context" then
      -- Check if there's a sign on this row
      local signs = vim.fn.sign_getplaced(layout.main_buf, { group = "GlabReview", lnum = i })
      if signs and signs[1] and #signs[1].signs > 0 then
        table.insert(comment_rows, i)
      end
    end
  end
  if #comment_rows == 0 then return end
  local target = nil
  if delta > 0 then
    for _, r in ipairs(comment_rows) do
      if r > current_row then target = r; break end
    end
    if not target then target = comment_rows[1] end
  else
    for i = #comment_rows, 1, -1 do
      if comment_rows[i] < current_row then target = comment_rows[i]; break end
    end
    if not target then target = comment_rows[#comment_rows] end
  end
  if target then
    vim.api.nvim_win_set_cursor(layout.main_win, { target, 0 })
  end
end

-- ─── Keymaps ─────────────────────────────────────────────────────────────────

function M.setup_keymaps(layout, state)
  local main_buf = layout.main_buf
  local sidebar_buf = layout.sidebar_buf
  local opts = { noremap = true, silent = true, nowait = true }

  local function map(buf, mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, vim.tbl_extend("force", opts, { buffer = buf }))
  end

  -- File navigation
  map(main_buf, "n", "]f", function() nav_file(layout, state, 1) end)
  map(main_buf, "n", "[f", function() nav_file(layout, state, -1) end)
  map(sidebar_buf, "n", "]f", function() nav_file(layout, state, 1) end)
  map(sidebar_buf, "n", "[f", function() nav_file(layout, state, -1) end)

  -- Comment navigation
  map(main_buf, "n", "]c", function() nav_comment(layout, state, 1) end)
  map(main_buf, "n", "[c", function() nav_comment(layout, state, -1) end)

  -- Comment creation
  map(main_buf, "n", "cc", function() M.create_comment_at_cursor(layout, state) end)
  map(main_buf, "v", "cc", function() M.create_comment_range(layout, state) end)

  -- Expand hidden lines
  map(main_buf, "n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
    local row = cursor[1]
    local line_data = state.line_data_cache[state.current_file]
    if line_data and line_data[row] and line_data[row].type == "hidden" then
      M.expand_hidden(layout, state)
    end
  end)

  -- Refresh
  map(main_buf, "n", "R", function()
    M.open(state.mr, nil)
  end)
  map(sidebar_buf, "n", "R", function()
    M.open(state.mr, nil)
  end)

  -- Quit
  local function quit()
    local split = require("glab_review.ui.split")
    split.close(layout)
  end
  map(main_buf, "n", "q", quit)
  map(sidebar_buf, "n", "q", quit)

  -- Sidebar: <CR> to jump to file
  map(sidebar_buf, "n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(layout.sidebar_win)
    local row = cursor[1]
    local file_start_row = 7  -- 1-indexed: header takes rows 1-6
    local idx = row - file_start_row + 1
    if idx >= 1 and idx <= #(state.files or {}) then
      state.current_file = idx
      M.render_sidebar(layout.sidebar_buf, state)
      local line_data = M.render_file_diff(
        layout.main_buf, state.files[idx], state.mr, state.discussions)
      state.line_data_cache[idx] = line_data
      vim.api.nvim_set_current_win(layout.main_win)
    end
  end)
end

-- ─── Main entry point ─────────────────────────────────────────────────────────

function M.open(mr, discussions)
  local client = require("glab_review.api.client")
  local endpoints = require("glab_review.api.endpoints")
  local git = require("glab_review.git")
  local split = require("glab_review.ui.split")

  local base_url, project = git.detect_project()
  if not base_url or not project then
    vim.notify("Could not detect GitLab project", vim.log.levels.ERROR)
    return
  end

  local encoded = client.encode_project(project)
  local result, err = client.get(base_url, endpoints.mr_diffs(encoded, mr.iid))
  if err then
    vim.notify("Failed to fetch diffs: " .. err, vim.log.levels.ERROR)
    return
  end

  local files = result and result.data or {}
  if type(files) ~= "table" then files = {} end

  local layout = split.create()

  local state = {
    mr = mr,
    files = files,
    current_file = 1,
    layout = layout,
    discussions = discussions or {},
    line_data_cache = {},
  }

  M.render_sidebar(layout.sidebar_buf, state)

  if #files > 0 then
    local line_data = M.render_file_diff(layout.main_buf, files[1], mr, state.discussions)
    state.line_data_cache[1] = line_data
  else
    vim.bo[layout.main_buf].modifiable = true
    vim.api.nvim_buf_set_lines(layout.main_buf, 0, -1, false, { "No diffs found." })
    vim.bo[layout.main_buf].modifiable = false
  end

  M.setup_keymaps(layout, state)
  vim.api.nvim_set_current_win(layout.main_win)
end

return M
