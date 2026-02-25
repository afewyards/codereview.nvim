-- lua/codereview/mr/diff_nav.lua
-- Navigation helpers for the diff viewer.
-- Handles file navigation, anchor calculation, jump-to-file/comment, scroll mode toggle,
-- and virt-line visibility adjustment.

local M = {}
local diff_state = require("codereview.mr.diff_state")
local diff_render = require("codereview.mr.diff_render")
local diff_sidebar = require("codereview.mr.diff_sidebar")

-- nvim_create_namespace returns the same ID for the same name — safe to redeclare.
local DIFF_NS = vim.api.nvim_create_namespace("codereview_diff")
local AIDRAFT_NS = vim.api.nvim_create_namespace("codereview_ai_draft")

-- ─── File navigation ─────────────────────────────────────────────────────────

--- Navigate to the adjacent file (delta = +1 next, -1 prev).
--- @param layout table
--- @param state table
--- @param delta number
function M.nav_file(layout, state, delta)
  local files = state.files or {}
  local next_idx = state.current_file + delta
  if next_idx < 1 or next_idx > #files then return end
  state.current_file = next_idx
  state.row_selection = {}
  diff_sidebar.render_sidebar(layout.sidebar_buf, state)
  local line_data, row_disc, row_ai = diff_render.render_file_diff(layout.main_buf, files[next_idx], state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
  diff_state.apply_file_result(state, next_idx, line_data, row_disc, row_ai)
  vim.api.nvim_win_set_cursor(layout.main_win, { 1, 0 })
end

--- Switch to a specific file by index (per-file mode).
--- @param layout table
--- @param state table
--- @param idx number
function M.switch_to_file(layout, state, idx)
  state.current_file = idx
  state.row_selection = {}
  diff_sidebar.render_sidebar(layout.sidebar_buf, state)
  local ld, rd, ra = diff_render.render_file_diff(
    layout.main_buf, state.files[idx], state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
  diff_state.apply_file_result(state, idx, ld, rd, ra)
end

--- Jump to a specific file, handling both scroll and per-file modes, and
--- transitioning out of summary mode if needed.
--- @param layout table
--- @param state table
--- @param file_idx number
function M.jump_to_file(layout, state, file_idx)
  if not state.files or not state.files[file_idx] then return end

  -- Transition out of summary mode into diff mode (mirrors sidebar click logic)
  if state.view_mode == "summary" then
    state.view_mode = "diff"
    state.current_file = file_idx
    vim.wo[layout.main_win].wrap = false
    vim.wo[layout.main_win].linebreak = false
    if state.scroll_mode then
      local result = diff_render.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
      diff_state.apply_scroll_result(state, result)
      diff_sidebar.render_sidebar(layout.sidebar_buf, state)
      for _, sec in ipairs(state.file_sections) do
        if sec.file_idx == file_idx then
          vim.api.nvim_win_set_cursor(layout.main_win, { sec.start_line, 0 })
          break
        end
      end
    else
      diff_sidebar.render_sidebar(layout.sidebar_buf, state)
      local ld, rd, ra = diff_render.render_file_diff(
        layout.main_buf, state.files[file_idx], state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
      diff_state.apply_file_result(state, file_idx, ld, rd, ra)
      vim.api.nvim_win_set_cursor(layout.main_win, { 1, 0 })
    end
    vim.api.nvim_set_current_win(layout.main_win)
    return
  end

  if state.scroll_mode then
    -- In scroll mode, jump to the file section
    if state.file_sections then
      for _, sec in ipairs(state.file_sections) do
        if sec.file_idx == file_idx then
          vim.api.nvim_win_set_cursor(layout.main_win, { sec.start_line, 0 })
          return
        end
      end
    end
  else
    -- Per-file mode: switch to the file
    M.switch_to_file(layout, state, file_idx)
    vim.api.nvim_win_set_cursor(layout.main_win, { 1, 0 })
  end
end

--- Jump to a specific comment or AI suggestion.
--- @param layout table
--- @param state table
--- @param entry table { file_idx, type, discussion?, suggestion? }
function M.jump_to_comment(layout, state, entry)
  if not entry.file_idx then return end

  if state.scroll_mode then
    local row_cache
    if entry.type == "ai_suggestion" then
      row_cache = state.scroll_row_ai
    else
      row_cache = state.scroll_row_disc
    end
    if row_cache then
      for r, items in pairs(row_cache) do
        local item_list = entry.type == "ai_suggestion" and { items } or items
        for _, item in ipairs(item_list) do
          local match = false
          if entry.type == "discussion" and item.id == entry.discussion.id then match = true end
          if entry.type == "ai_suggestion" and item == entry.suggestion then match = true end
          if match then
            vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
            M.ensure_virt_lines_visible(layout.main_win, layout.main_buf, r)
            return
          end
        end
      end
    end
  else
    if state.current_file ~= entry.file_idx then
      M.switch_to_file(layout, state, entry.file_idx)
    end
    local row_cache
    if entry.type == "ai_suggestion" then
      row_cache = state.row_ai_cache[entry.file_idx]
    else
      row_cache = state.row_disc_cache[entry.file_idx]
    end
    if row_cache then
      for r, items in pairs(row_cache) do
        local item_list = entry.type == "ai_suggestion" and { items } or items
        for _, item in ipairs(item_list) do
          local match = false
          if entry.type == "discussion" and item.id == entry.discussion.id then match = true end
          if entry.type == "ai_suggestion" and item == entry.suggestion then match = true end
          if match then
            vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
            M.ensure_virt_lines_visible(layout.main_win, layout.main_buf, r)
            return
          end
        end
      end
    end
  end
end

-- ─── Anchor helpers ───────────────────────────────────────────────────────────

--- Extract a position anchor from line_data at cursor_row.
--- @param line_data table[] line_data array (per-file or scroll mode)
--- @param cursor_row number 1-indexed buffer row
--- @param file_idx number? fallback file_idx (for per-file line_data which lacks file_idx)
--- @return table anchor { file_idx, old_line?, new_line? }
function M.find_anchor(line_data, cursor_row, file_idx)
  local data = line_data[cursor_row]
  if not data then return { file_idx = file_idx or 1 } end
  local fi = data.file_idx or file_idx or 1
  local item = data.item
  if item then
    return { file_idx = fi, old_line = item.old_line, new_line = item.new_line }
  end
  return { file_idx = fi }
end

--- Find the buffer row in line_data that best matches an anchor.
--- Priority: exact new_line (or old_line for deletes) > closest new_line > first diff line in file.
--- @param line_data table[] target view's line_data
--- @param anchor table { file_idx, old_line?, new_line? }
--- @param fallback_file_idx number? override file_idx for per-file line_data
--- @return number row 1-indexed buffer row
function M.find_row_for_anchor(line_data, anchor, fallback_file_idx)
  local target_fi = anchor.file_idx
  local target_new = anchor.new_line
  local target_old = anchor.old_line
  local has_target = target_new or target_old

  local first_diff_row = nil
  local closest_row = nil
  local closest_dist = math.huge

  for row, data in ipairs(line_data) do
    local fi = data.file_idx or fallback_file_idx
    if fi == target_fi then
      local item = data.item
      if item then
        if not first_diff_row then first_diff_row = row end

        if has_target then
          -- Exact match: prefer new_line; for delete-only anchors use old_line
          if target_new and item.new_line == target_new then return row end
          if not target_new and target_old and item.old_line == target_old then return row end

          -- Closest match by new_line distance
          local item_line = item.new_line or item.old_line
          local anchor_line = target_new or target_old
          if item_line and anchor_line then
            local dist = math.abs(item_line - anchor_line)
            if dist < closest_dist then
              closest_dist = dist
              closest_row = row
            end
          end
        end
      end
    end
  end

  if not has_target and first_diff_row then return first_diff_row end
  if closest_row then return closest_row end
  if first_diff_row then return first_diff_row end
  return 1
end

-- ─── Annotated row utility ───────────────────────────────────────────────────

--- Merged sorted list of rows with any annotation (comments or AI).
--- @param row_disc table map of row->discussions
--- @param row_ai table map of row->AI suggestions
--- @return number[] sorted unique row numbers
function M.get_annotated_rows(row_disc, row_ai)
  local seen = {}
  for r in pairs(row_disc or {}) do seen[r] = true end
  for r in pairs(row_ai or {}) do seen[r] = true end
  local rows = {}
  for r in pairs(seen) do table.insert(rows, r) end
  table.sort(rows)
  return rows
end

-- ─── Virtual-line visibility ─────────────────────────────────────────────────

--- Scroll the window so that the virt_lines attached to `row` are visible.
--- @param win number window handle
--- @param buf number buffer handle
--- @param row number 1-indexed buffer row
function M.ensure_virt_lines_visible(win, buf, row)
  if not vim.api.nvim_win_is_valid(win) then return end
  local virt_count = 0
  for _, ns in ipairs({ DIFF_NS, AIDRAFT_NS }) do
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details and details.virt_lines then
        virt_count = virt_count + #details.virt_lines
      end
    end
  end

  local win_height = vim.api.nvim_win_get_height(win)
  local total_height = 1 + virt_count -- comment row + virtual lines
  local new_topline = row - math.floor((win_height - total_height) / 2)
  if new_topline < 1 then new_topline = 1 end
  if new_topline > row then new_topline = row end
  vim.fn.winrestview({ topline = new_topline })
end

-- ─── Context adjustment ──────────────────────────────────────────────────────

--- Adjust the context line count and re-render, preserving cursor anchor position.
--- @param layout table
--- @param state table
--- @param delta number lines to add (positive) or remove (negative)
function M.adjust_context(layout, state, delta)
  local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
  state.context = math.max(1, state.context + delta)
  if state.scroll_mode then
    local anchor = M.find_anchor(state.scroll_line_data, cursor_row)
    diff_state.clear_diff_cache(state)
    local result = diff_render.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
    diff_state.apply_scroll_result(state, result)
    local row = M.find_row_for_anchor(state.scroll_line_data, anchor)
    vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
  else
    local per_file_ld = state.line_data_cache[state.current_file]
    local anchor = M.find_anchor(per_file_ld or {}, cursor_row, state.current_file)
    local file = state.files and state.files[state.current_file]
    if not file then return end
    diff_state.clear_diff_cache(state, file.new_path or file.old_path)
    local ld, row_disc, row_ai = diff_render.render_file_diff(
      layout.main_buf, file, state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
    diff_state.apply_file_result(state, state.current_file, ld, row_disc, row_ai)
    local row = M.find_row_for_anchor(ld, anchor, state.current_file)
    vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
  end
  vim.notify("Context: " .. state.context .. " lines", vim.log.levels.INFO)
end

-- ─── Scroll mode helpers ─────────────────────────────────────────────────────

--- Return the file_idx under the cursor in scroll mode.
--- @param layout table
--- @param state table
--- @return number file_idx
function M.current_file_from_cursor(layout, state)
  local row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
  local sections = state.file_sections
  if #sections == 0 then return 1 end
  local lo, hi = 1, #sections
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if row >= sections[mid].start_line then
      lo = mid
    else
      hi = mid - 1
    end
  end
  if row < sections[lo].start_line then return 1 end
  return sections[lo].file_idx
end

--- Toggle between per-file and all-files scroll mode, preserving cursor position.
--- @param layout table
--- @param state table
function M.toggle_scroll_mode(layout, state)
  local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
  state.row_selection = {}

  if state.scroll_mode then
    -- EXITING scroll mode → per-file
    local anchor = M.find_anchor(state.scroll_line_data, cursor_row)
    state.current_file = anchor.file_idx
    state.scroll_mode = false

    local file = state.files[state.current_file]
    if file then
      local ld, rd, ra = diff_render.render_file_diff(layout.main_buf, file, state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
      diff_state.apply_file_result(state, state.current_file, ld, rd, ra)
      local row = M.find_row_for_anchor(ld, anchor, state.current_file)
      vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
    end
  else
    -- ENTERING scroll mode → all-files
    local per_file_ld = state.line_data_cache[state.current_file]
    local anchor = M.find_anchor(per_file_ld or {}, cursor_row, state.current_file)
    state.scroll_mode = true

    local result = diff_render.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user, nil, state.git_diff_cache)
    diff_state.apply_scroll_result(state, result)
    local row = M.find_row_for_anchor(state.scroll_line_data, anchor)
    vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
  end

  diff_sidebar.render_sidebar(layout.sidebar_buf, state)
  vim.notify(state.scroll_mode and "All-files view" or "Per-file view", vim.log.levels.INFO)
end

return M
