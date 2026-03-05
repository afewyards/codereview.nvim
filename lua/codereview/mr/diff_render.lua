-- lua/codereview/mr/diff_render.lua
-- Rendering functions for the diff viewer.
-- Handles buffer content, highlights, extmarks, and virtual-text placement.

local M = {}
local config = require("codereview.config")
local tvl = require("codereview.mr.thread_virt_lines")
local wrap_text = tvl.wrap_text
local md_virt_line = tvl.md_virt_line
local is_resolved = tvl.is_resolved

-- LINE_NR_WIDTH: "%5d | %-5d " = 5+3+5+1 = 14 chars
local LINE_NR_WIDTH = 14 -- luacheck: ignore
local COMMENT_PAD = string.rep(" ", 4)

-- nvim_create_namespace returns the same ID for the same name — safe to declare
-- in multiple modules.
local DIFF_NS = vim.api.nvim_create_namespace("codereview_diff")
local AIDRAFT_NS = vim.api.nvim_create_namespace("codereview_ai_draft")
local SEPARATOR_NS = vim.api.nvim_create_namespace("codereview_separator")

-- Module-level cache for syntax file paths to avoid repeated runtimepath scans.
-- Persists across re-renders within the same session.
local syntax_file_cache = {} -- { [filetype] = path_string | false }

-- Track SHAs we've already attempted to fetch to avoid repeated network calls.
local fetched_shas = {}

--- Fetch git objects for the given SHAs if they're not available locally.
--- Only attempts once per unique SHA pair.
function M.ensure_git_objects(base_sha, head_sha)
  local key = base_sha .. head_sha
  if fetched_shas[key] then
    return
  end
  fetched_shas[key] = true
  vim.fn.system({ "git", "fetch", "origin", base_sha, head_sha })
end

-- ─── Formatting helpers ───────────────────────────────────────────────────────

function M.format_line_number(old_nr, new_nr)
  local old_str = old_nr and string.format("%5d", old_nr) or "     "
  local new_str = new_nr and string.format("%-5d", new_nr) or "     "
  return old_str .. " | " .. new_str .. " "
end

-- ─── Highlight application ────────────────────────────────────────────────────

local function apply_line_hl(buf, row, hl_group)
  vim.api.nvim_buf_set_extmark(buf, DIFF_NS, row, 0, { line_hl_group = hl_group, priority = 50 })
end

local function apply_word_hl(buf, row, col_start, col_end, hl_group)
  if col_start >= col_end then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, DIFF_NS, row, col_start, {
    end_col = col_end,
    hl_group = hl_group,
  })
end

-- Export for use in diff.lua (sidebar renderer needs these)
M.apply_line_hl = apply_line_hl
M.apply_word_hl = apply_word_hl

-- ─── Hunk separator placement ─────────────────────────────────────────────────

local function place_hunk_separators(buf, data_list, file_scoped, file_line_count)
  vim.api.nvim_buf_clear_namespace(buf, SEPARATOR_NS, 0, -1)
  local cfg = config.get().diff
  if cfg.separator_lines <= 0 or cfg.separator_char == "" then
    return
  end
  local win_width = 80
  if vim.api.nvim_list_wins then
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == buf then
        win_width = vim.api.nvim_win_get_width(w)
        break
      end
    end
  end

  local sep_line = string.rep(cfg.separator_char, win_width)
  local full_virt = { { sep_line, "CodeReviewHunkSeparator" } }

  -- Build hint line for unfold keybind
  local keymaps = require("codereview.keymaps")
  local toggle_key = keymaps.get("toggle_full_file") or "<C-f>"
  local hint = " Press " .. toggle_key .. " to show full file "
  local hint_len = vim.fn.strdisplaywidth(hint)
  local remaining = win_width - hint_len

  local sep_virt = {}
  if remaining >= 2 then
    local top_lines = math.floor((cfg.separator_lines - 1) / 2)
    local bottom_lines = cfg.separator_lines - 1 - top_lines
    local left_pad = math.floor(remaining / 2)
    local right_pad = remaining - left_pad
    local hint_virt = {
      { string.rep(cfg.separator_char, left_pad), "CodeReviewHunkSeparator" },
      { hint, "CodeReviewHunkSeparatorHint" },
      { string.rep(cfg.separator_char, right_pad), "CodeReviewHunkSeparator" },
    }
    for _ = 1, top_lines do
      table.insert(sep_virt, full_virt)
    end
    table.insert(sep_virt, hint_virt)
    for _ = 1, bottom_lines do
      table.insert(sep_virt, full_virt)
    end
  else
    -- Window too narrow for hint; fall back to plain separator lines
    for _ = 1, cfg.separator_lines do
      table.insert(sep_virt, full_virt)
    end
  end

  local prev_hunk, prev_file = nil, nil
  for i, data in ipairs(data_list) do
    local cur_hunk = data.item and data.item.hunk_idx
    local cur_file = data.file_idx
    if cur_hunk and prev_hunk and cur_hunk ~= prev_hunk then
      if not file_scoped or cur_file == prev_file then
        local anchor_row = i - 2
        if anchor_row >= 0 then
          vim.api.nvim_buf_set_extmark(buf, SEPARATOR_NS, anchor_row, 0, {
            virt_lines = sep_virt,
            virt_lines_above = false,
          })
        end
      end
    end
    if cur_hunk then
      prev_hunk = cur_hunk
      prev_file = cur_file
    end
  end

  -- Edge separators: top/bottom of per-file view when content is truncated
  if not file_scoped then
    local function build_edge_hint(arrow)
      local edge_hint = " " .. arrow .. " Press " .. toggle_key .. " to show full file " .. arrow .. " "
      local edge_hint_len = vim.fn.strdisplaywidth(edge_hint)
      local edge_remaining = win_width - edge_hint_len
      if edge_remaining >= 2 then
        local left = math.floor(edge_remaining / 2)
        local right = edge_remaining - left
        return {
          { string.rep(cfg.separator_char, left), "CodeReviewHunkSeparator" },
          { edge_hint, "CodeReviewHunkSeparatorHint" },
          { string.rep(cfg.separator_char, right), "CodeReviewHunkSeparator" },
        }
      end
      return full_virt
    end

    -- Top edge: at the first line if file doesn't start at line 1
    local starts_at_bof = #data_list > 0
      and data_list[1].item
      and data_list[1].item.new_line
      and data_list[1].item.new_line <= 1
      and data_list[1].item.old_line
      and data_list[1].item.old_line <= 1
    if #data_list > 0 and not starts_at_bof then
      vim.api.nvim_buf_set_extmark(buf, SEPARATOR_NS, 0, 0, {
        virt_lines = { build_edge_hint("▲"), full_virt },
        virt_lines_above = true,
      })
    end

    -- Bottom edge: at the last line if file doesn't reach EOF
    local n = #data_list
    local at_eof = false
    if file_line_count and n > 0 then
      for i = n, 1, -1 do
        if data_list[i].item and data_list[i].item.new_line then
          at_eof = data_list[i].item.new_line >= file_line_count
          break
        end
      end
    end
    if n > 0 and not at_eof then
      vim.api.nvim_buf_set_extmark(buf, SEPARATOR_NS, n - 1, 0, {
        virt_lines = { full_virt, build_edge_hint("▼") },
        virt_lines_above = false,
      })
    end
  end
end

-- ─── Discussion helpers ───────────────────────────────────────────────────────

local function is_outdated(discussion, review)
  local note = discussion.notes and discussion.notes[1]
  if not note then
    return false
  end
  if note.position and note.position.outdated then
    return true
  end
  if not review or not review.head_sha then
    return false
  end
  if not note.position or not note.position.head_sha then
    return false
  end
  return note.position.head_sha ~= review.head_sha
end

local function discussion_matches_file(discussion, file_diff, review)
  local note = discussion.notes and discussion.notes[1]
  if not note or not note.position then
    return false
  end
  if is_outdated(discussion, review) and note.change_position then
    local cp = note.change_position
    local path = cp.new_path or cp.old_path
    return path == file_diff.new_path or path == file_diff.old_path
  end
  local pos = note.position
  local path = pos.new_path or pos.old_path
  return path == file_diff.new_path or path == file_diff.old_path
end

local function discussion_line(discussion, review)
  local note = discussion.notes and discussion.notes[1]
  if not note or not note.position then
    return nil
  end
  if is_outdated(discussion, review) then
    if note.position.outdated then
      -- GitHub outdated: new_line is already set to the fallback originalLine
      local end_line = tonumber(note.position.new_line) or tonumber(note.position.old_line)
      return end_line, nil, true
    end
    if note.change_position then
      -- GitLab outdated: remap to change_position lines
      local cp = note.change_position
      local end_line = tonumber(cp.new_line) or tonumber(cp.old_line)
      return end_line, nil, true
    end
    -- GitLab outdated without change_position: skip
    return nil
  end
  local pos = note.position
  local end_line = tonumber(pos.new_line) or tonumber(pos.old_line)
  -- Range comments: derive start from GitHub start_line or GitLab line_range
  local start_line = tonumber(pos.start_line) or tonumber(pos.start_new_line) or tonumber(pos.start_old_line)
  return end_line, start_line
end

-- Export discussion helpers for use in diff.lua (sidebar needs them)
M.is_outdated = is_outdated
M.discussion_matches_file = discussion_matches_file
M.discussion_line = discussion_line

-- ─── AI suggestion rendering ──────────────────────────────────────────────────

--- Render AI suggestions for a single row as virtual lines with sign placement.
--- @param buf number buffer handle
--- @param row number 1-indexed buffer row
--- @param sugs table[] array of suggestion objects at this row
--- @param row_selection table|nil current row_selection state
local function render_ai_suggestions_at_row(buf, row, sugs, row_selection)
  -- Determine highest severity for sign placement
  local severity_rank = { info = 1, warning = 2, error = 3 }
  local max_severity = "info"
  for _, sug in ipairs(sugs) do
    local sev = sug.severity or "info"
    if (severity_rank[sev] or 1) > (severity_rank[max_severity] or 1) then
      max_severity = sev
    end
  end
  local sign_by_sev = {
    info = "CodeReviewAISign",
    warning = "CodeReviewAIWarningSign",
    error = "CodeReviewAIErrorSign",
  }
  pcall(vim.fn.sign_place, 0, "CodeReviewAI", sign_by_sev[max_severity] or "CodeReviewAISign", buf, { lnum = row })

  local sel = row_selection and row_selection[row]
  local sel_ai_idx = sel and sel.type == "ai" and sel.index or nil
  local sug_count = #sugs
  local virt_lines = {}
  local sel_ai_offset = nil

  for i, suggestion in ipairs(sugs) do
    local is_selected = (sel_ai_idx == i)
    local drafted = suggestion.status == "accepted" or suggestion.status == "edited"
    local severity = suggestion.severity or "info"
    local is_error = severity == "error"

    -- Border chars by severity: dashed for info/warning, solid for error
    local top_l = is_error and "┏" or "┌"
    local top_fill_c = is_error and "━" or "╌"
    local bot_l = is_error and "┗" or "└"
    local bot_fill_c = is_error and "━" or "╌"

    -- Highlights by severity
    local sev_bdr = is_error and "CodeReviewAIErrorBorder"
      or severity == "warning" and "CodeReviewAIWarningBorder"
      or "CodeReviewAIDraftBorder"
    local sev_body = is_error and "CodeReviewAIError"
      or severity == "warning" and "CodeReviewAIWarning"
      or "CodeReviewAIDraft"

    local ai_status_hl = is_error and "CodeReviewAIErrorBorder"
      or severity == "warning" and "CodeReviewAIWarningBorder"
      or "CodeReviewAIDraftBorder"
    local bdr = drafted and "CodeReviewCommentBorder" or sev_bdr
    local body_hl = drafted and "CodeReviewComment" or sev_body

    -- Header: ◆ AI · {severity} [✓ drafted]
    local header_label = drafted and (" ◆ AI · " .. severity .. " ✓ drafted ")
      or (" ◆ AI · " .. severity .. " ")
    local header_fill = math.max(0, 62 - #header_label)

    local sel_pre = is_selected and "██  " or COMMENT_PAD -- luacheck: ignore
    local sel_blk = is_selected and { "██", ai_status_hl } or nil

    if is_selected then
      sel_ai_offset = #virt_lines
    end

    -- Header line
    local header_line = {}
    if sel_blk then
      table.insert(header_line, sel_blk)
    end
    table.insert(header_line, { (is_selected and "  " or COMMENT_PAD) .. top_l .. header_label, bdr })
    table.insert(header_line, { string.rep(top_fill_c, header_fill), bdr })
    table.insert(virt_lines, header_line)

    -- Body (always heavy left bar)
    for _, bl in ipairs(wrap_text(suggestion.comment, config.get().diff.comment_width)) do
      if sel_blk then
        table.insert(virt_lines, md_virt_line({ sel_blk, { "  ┃ ", bdr } }, bl, body_hl))
      else
        table.insert(virt_lines, md_virt_line({ COMMENT_PAD .. "┃ ", bdr }, bl, body_hl))
      end
    end

    -- Footer: keybinds + counter when selected; short cap otherwise
    local footer_parts = {}
    if is_selected then
      local footer_content = drafted and "x:dismiss" or "a:accept  x:dismiss  e:edit"
      local counter = sug_count > 1 and (" " .. i .. "/" .. sug_count) or ""
      local footer_fill = math.max(0, 62 - #footer_content - #counter - 1)
      footer_parts[#footer_parts + 1] = sel_blk
      footer_parts[#footer_parts + 1] = { "  " .. bot_l .. " ", bdr }
      footer_parts[#footer_parts + 1] = { footer_content, body_hl }
      if counter ~= "" then
        footer_parts[#footer_parts + 1] = { " " .. string.rep(bot_fill_c, footer_fill) .. counter, bdr }
      else
        footer_parts[#footer_parts + 1] = { " " .. string.rep(bot_fill_c, footer_fill), bdr }
      end
    else
      footer_parts[#footer_parts + 1] = { COMMENT_PAD .. bot_l .. bot_fill_c .. bot_fill_c, bdr }
    end
    table.insert(virt_lines, footer_parts)
  end

  pcall(vim.api.nvim_buf_set_extmark, buf, AIDRAFT_NS, row - 1, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
  })
  return #virt_lines, sel_ai_offset
end

M.render_ai_suggestions_at_row = render_ai_suggestions_at_row

--- Return the carrier rows immediately following anchor_row (contiguous block).
local function find_carrier_rows(line_data, anchor_row)
  local carriers = {}
  for i = anchor_row + 1, #line_data do
    if line_data[i].type == "carrier" then
      table.insert(carriers, i)
    else
      break
    end
  end
  return carriers
end

--- Selective per-row extmark update when only the selection indicator changes.
--- Clears AIDRAFT_NS and DIFF_NS virt_lines extmarks on the target row, then
--- re-renders AI suggestions and comment threads for that row only.
--- @param buf number buffer handle
--- @param row number 1-indexed row
--- @param row_selection table current row_selection state
--- @param row_ai table row → suggestions list map
--- @param row_disc table row → discussions list map
--- @param current_user string
--- @param review table
--- @param editing_note table|nil
function M.update_selection_at_row(
  buf,
  row,
  row_selection,
  row_ai,
  row_disc,
  current_user,
  review,
  editing_note,
  line_data
)
  -- Clear AIDRAFT_NS extmarks on this row only
  local ai_marks = vim.api.nvim_buf_get_extmarks(buf, AIDRAFT_NS, { row - 1, 0 }, { row - 1, -1 }, {})
  for _, mark in ipairs(ai_marks) do
    pcall(vim.api.nvim_buf_del_extmark, buf, AIDRAFT_NS, mark[1])
  end

  -- Clear DIFF_NS virt_lines extmarks on this row only (not line_hl or virt_text)
  local diff_marks = vim.api.nvim_buf_get_extmarks(buf, DIFF_NS, { row - 1, 0 }, { row - 1, -1 }, { details = true })
  for _, mark in ipairs(diff_marks) do
    local details = mark[4]
    if details and details.virt_lines then
      pcall(vim.api.nvim_buf_del_extmark, buf, DIFF_NS, mark[1])
    end
  end

  local carriers = line_data and find_carrier_rows(line_data, row) or {}
  for _, cr in ipairs(carriers) do
    local marks = vim.api.nvim_buf_get_extmarks(buf, DIFF_NS, { cr - 1, 0 }, { cr - 1, -1 }, { details = true })
    for _, mark in ipairs(marks) do
      if mark[4] and mark[4].virt_lines then
        pcall(vim.api.nvim_buf_del_extmark, buf, DIFF_NS, mark[1])
      end
    end
  end

  local sel_virt_offset = nil
  local sel_row = nil
  local sel_note_offset = nil

  -- Re-render AI suggestions at row
  if row_ai and row_ai[row] then
    local _, ai_sel = render_ai_suggestions_at_row(buf, row, row_ai[row], row_selection)
    if ai_sel then
      sel_virt_offset = ai_sel
    end
  end

  -- Re-render comment threads at row
  if row_disc and row_disc[row] then
    for _, disc in ipairs(row_disc[row]) do
      local notes = disc.notes
      if notes and #notes > 0 then
        local sel = row_selection and row_selection[row]
        local sel_idx = sel and sel.type == "comment" and sel.disc_id == disc.id and sel.note_idx or nil
        local _, _, outdated = discussion_line(disc, review)
        local result = tvl.build(disc, {
          sel_idx = sel_idx,
          current_user = current_user,
          outdated = outdated,
          editing_note = editing_note,
          spacer_height = editing_note and editing_note.spacer_height or 0,
          gutter = 4,
        })
        local segments = result.note_segments or { result }
        for seg_i, seg in ipairs(segments) do
          local target_row = (seg_i == 1) and row or carriers[seg_i - 1]
          if target_row and #seg.virt_lines > 0 then
            pcall(vim.api.nvim_buf_set_extmark, buf, DIFF_NS, target_row - 1, 0, {
              virt_lines = seg.virt_lines,
              virt_lines_above = false,
            })
          end
          if sel_row == nil and seg.sel_line_offset ~= nil then
            sel_row = (seg_i == 1) and row or carriers[seg_i - 1]
            sel_note_offset = seg.sel_line_offset
          end
        end
      end
    end
  end

  return sel_virt_offset, sel_row, sel_note_offset
end

-- ─── Lookup map builders ──────────────────────────────────────────────────────

--- Build a line_number -> row map from line_data (per-file mode).
--- new_line takes priority; old_line indexed only if the row has no new_line.
--- When the same integer appears as both a new_line on one row and an old_line on
--- another, the new_line row wins (it will overwrite any earlier old_line entry).
function M.build_line_to_row(line_data)
  local map = {}
  for row, data in ipairs(line_data) do
    if data.item then
      if data.item.new_line then
        map[data.item.new_line] = row
      elseif data.item.old_line and not map[data.item.old_line] then
        map[data.item.old_line] = row
      end
    end
  end
  return map
end

--- Build a "file_idx:line_number" -> row map from all_line_data (scroll mode).
--- Same priority rule: new_line wins over old_line for the same key.
function M.build_line_to_row_scroll(all_line_data)
  local map = {}
  for row, data in ipairs(all_line_data) do
    if data.item and data.file_idx then
      if data.item.new_line then
        map[data.file_idx .. ":" .. data.item.new_line] = row
      elseif data.item.old_line then
        local key = data.file_idx .. ":" .. data.item.old_line
        if not map[key] then
          map[key] = row
        end
      end
    end
  end
  return map
end

-- ─── Comment sign placement ────────────────────────────────────────────────────

function M.place_comment_signs(
  buf,
  line_data,
  discussions,
  file_diff,
  row_selection,
  current_user,
  review,
  editing_note,
  line_to_row
)
  -- Remove old signs for this buffer
  pcall(vim.fn.sign_unplace, "CodeReview", { buffer = buf })

  -- Track which rows have discussions (for keymap lookups)
  local row_discussions = {}
  local map = line_to_row or M.build_line_to_row(line_data)
  -- Per-anchor carrier offset: tracks how many carrier rows earlier discussions have consumed
  local carrier_offsets = {}

  for _, discussion in ipairs(discussions or {}) do
    if discussion_matches_file(discussion, file_diff, review) then
      local target_line, range_start, outdated = discussion_line(discussion, review)
      if target_line then
        local sign_name = is_resolved(discussion) and "CodeReviewCommentSign" or "CodeReviewUnresolvedSign"
        -- Place signs on all lines in the range (visual only; navigation uses target_line)
        if range_start and range_start ~= target_line then
          for ln = range_start, target_line - 1 do
            local row = map[ln]
            if row then
              pcall(vim.fn.sign_place, 0, "CodeReview", sign_name, buf, { lnum = row })
            end
          end
        end
        -- Find the end-line row for the inline thread (O(1) lookup)
        local row = map[target_line]
        if row then
          -- Place gutter sign (also covers single-line comments)
          pcall(vim.fn.sign_place, 0, "CodeReview", sign_name, buf, { lnum = row })

          -- Render full comment thread inline, spreading replies across carrier rows
          local notes = discussion.notes
          if notes and #notes > 0 then
            local sel = row_selection and row_selection[row]
            local sel_idx = sel and sel.type == "comment" and sel.disc_id == discussion.id and sel.note_idx or nil
            local result = tvl.build(discussion, {
              sel_idx = sel_idx,
              current_user = current_user,
              outdated = outdated,
              editing_note = editing_note,
              spacer_height = editing_note and editing_note.spacer_height or 0,
              gutter = 4,
            })
            local carriers = find_carrier_rows(line_data, row)
            local offset = carrier_offsets[row] or 0
            local segments = result.note_segments or { result }
            for seg_i, seg in ipairs(segments) do
              local target_row = (seg_i == 1) and row or carriers[offset + seg_i - 1]
              if target_row and #seg.virt_lines > 0 then
                pcall(vim.api.nvim_buf_set_extmark, buf, DIFF_NS, target_row - 1, 0, {
                  virt_lines = seg.virt_lines,
                  virt_lines_above = false,
                })
              end
            end
            carrier_offsets[row] = offset + math.max(0, #segments - 1)
          end

          -- Store discussion for this row
          if not row_discussions[row] then
            row_discussions[row] = {}
          end
          table.insert(row_discussions[row], discussion)
        end
      end
    end
  end

  return row_discussions
end

-- ─── AI suggestions placement ─────────────────────────────────────────────────

function M.place_ai_suggestions(buf, line_data, suggestions, file_diff, row_selection, line_to_row)
  -- Clear old AI signs and extmarks
  pcall(vim.fn.sign_unplace, "CodeReviewAI", { buffer = buf })
  vim.api.nvim_buf_clear_namespace(buf, AIDRAFT_NS, 0, -1)

  local row_ai_map = {}
  local map = line_to_row or M.build_line_to_row(line_data)

  -- Pass 1: gather suggestions into row_ai_map (no rendering)
  for _, suggestion in ipairs(suggestions or {}) do
    if suggestion.status ~= "dismissed" then
      local path = file_diff.new_path or file_diff.old_path
      if suggestion.file == path then
        -- O(1) lookup by new_line
        local matched_row = map[suggestion.line]
        -- Fuzzy fallback: if AI provided a code snippet, verify the matched line
        -- contains it. If not, search all lines for a better match.
        if suggestion.code and suggestion.code ~= "" then
          local code = suggestion.code
          if matched_row then
            local text = line_data[matched_row].item and line_data[matched_row].item.text or ""
            if not vim.trim(text):find(code, 1, true) then
              matched_row = nil -- line number was wrong, search by code
            end
          end
          if not matched_row then
            for row, data in ipairs(line_data) do
              if data.item and data.item.new_line then
                local text = vim.trim(data.item.text or "")
                if text:find(code, 1, true) then
                  matched_row = row
                  break
                end
              end
            end
          end
        end
        if matched_row then
          if not row_ai_map[matched_row] then
            row_ai_map[matched_row] = {}
          end
          table.insert(row_ai_map[matched_row], suggestion)
        end
      end
    end
  end

  -- Pass 2: render all suggestions per row with selection awareness
  for row, sugs in pairs(row_ai_map) do
    render_ai_suggestions_at_row(buf, row, sugs, row_selection)
  end

  return row_ai_map
end

function M.place_ai_suggestions_all(buf, all_line_data, file_sections, suggestions, row_selection, scroll_map)
  -- Clear old AI signs and extmarks
  pcall(vim.fn.sign_unplace, "CodeReviewAI", { buffer = buf })
  vim.api.nvim_buf_clear_namespace(buf, AIDRAFT_NS, 0, -1)

  local scroll_row_ai = {}
  local smap = scroll_map or M.build_line_to_row_scroll(all_line_data)

  -- Pass 1: gather suggestions into scroll_row_ai (no rendering)
  for _, suggestion in ipairs(suggestions or {}) do
    if suggestion.status ~= "dismissed" then
      for _, section in ipairs(file_sections) do
        local fpath = section.file.new_path or section.file.old_path
        if suggestion.file == fpath then
          -- O(1) lookup by file_idx:new_line
          local matched_row = smap[section.file_idx .. ":" .. suggestion.line]
          -- Fuzzy fallback: verify code snippet matches, search if not
          if suggestion.code and suggestion.code ~= "" then
            local code = suggestion.code
            if matched_row then
              local text = all_line_data[matched_row].item and all_line_data[matched_row].item.text or ""
              if not vim.trim(text):find(code, 1, true) then
                matched_row = nil
              end
            end
            if not matched_row then
              for i = section.start_line, section.end_line do
                local data = all_line_data[i]
                if data and data.item and data.item.new_line and data.file_idx == section.file_idx then
                  local text = vim.trim(data.item.text or "")
                  if text:find(code, 1, true) then
                    matched_row = i
                    break
                  end
                end
              end
            end
          end
          if matched_row then
            if not scroll_row_ai[matched_row] then
              scroll_row_ai[matched_row] = {}
            end
            table.insert(scroll_row_ai[matched_row], suggestion)
          end
          break
        end
      end
    end
  end

  -- Pass 2: render all suggestions per row with selection awareness
  for row, sugs in pairs(scroll_row_ai) do
    render_ai_suggestions_at_row(buf, row, sugs, row_selection)
  end

  return scroll_row_ai
end

-- ─── Diff rendering ───────────────────────────────────────────────────────────

function M.render_file_diff(
  buf,
  file_diff,
  review,
  discussions,
  context,
  ai_suggestions,
  row_selection,
  current_user,
  editing_note,
  diff_cache,
  commit_filter
)
  local parser = require("codereview.mr.diff_parser")
  if not context then
    context = config.get().diff.context
  end

  local path = file_diff.new_path or file_diff.old_path
  local filter_suffix = commit_filter and (":" .. commit_filter.from_sha .. ".." .. commit_filter.to_sha) or ""
  local cache_key = path and (path .. ":" .. context .. filter_suffix) or nil
  local cached = diff_cache and cache_key and diff_cache[cache_key]

  local hunks, display, file_line_count

  if cached then
    hunks = cached.hunks -- luacheck: ignore 311
    display = cached.display
    file_line_count = cached.file_line_count
  else
    -- Try local git diff with more context lines; fall back to API diff
    local diff_text = file_diff.diff or ""
    local base_sha = commit_filter and commit_filter.from_sha or review.base_sha
    local head_sha = commit_filter and commit_filter.to_sha or review.head_sha
    if base_sha and head_sha and path then
      local result = vim.fn.system({
        "git",
        "diff",
        "-U" .. context,
        base_sha,
        head_sha,
        "--",
        path,
      })
      if vim.v.shell_error == 0 and result ~= "" then
        diff_text = result
      end
    end

    hunks = parser.parse_hunks(diff_text)
    display = parser.build_display(hunks, 99999)

    -- Get file line count for BOF/EOF detection
    if path and head_sha then
      local wc = vim.fn.system({
        "git",
        "show",
        head_sha .. ":" .. path,
      })
      if vim.v.shell_error == 0 then
        file_line_count = select(2, wc:gsub("\n", "\n"))
      end
    end

    if diff_cache and cache_key then
      diff_cache[cache_key] = {
        hunks = hunks,
        display = display,
        file_line_count = file_line_count,
      }
    end
  end

  -- Pre-compute carrier line counts: diff_line -> number of reply notes needing carriers
  local disc_carrier_counts = {}
  for _, disc in ipairs(discussions or {}) do
    if discussion_matches_file(disc, file_diff, review) then
      local target_line = discussion_line(disc, review)
      if target_line then
        local non_system_count = 0
        for _, note in ipairs(disc.notes or {}) do
          if not note.system then
            non_system_count = non_system_count + 1
          end
        end
        local carriers = math.max(0, non_system_count - 1)
        if carriers > 0 then
          disc_carrier_counts[target_line] = (disc_carrier_counts[target_line] or 0) + carriers
        end
      end
    end
  end

  local lines = {}
  local line_data = {}

  for _, item in ipairs(display) do
    if item.type ~= "hunk_boundary" then
      table.insert(lines, item.text or "")
      table.insert(line_data, { type = item.type, item = item })
      local target = item.new_line or item.old_line
      local carrier_count = target and disc_carrier_counts[target] or 0
      for k = 1, carrier_count do
        table.insert(lines, "")
        table.insert(line_data, { type = "carrier", anchor_line = target, carrier_idx = k })
      end
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Set syntax from file extension for code highlighting
  local ft_path = file_diff.new_path or file_diff.old_path or ""
  local ft = vim.filetype.match({ filename = ft_path })
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
    if data.item and (data.item.old_line or data.item.new_line) then
      vim.api.nvim_buf_set_extmark(buf, DIFF_NS, row, 0, {
        virt_text = { { M.format_line_number(data.item.old_line, data.item.new_line), "CodeReviewLineNr" } },
        virt_text_pos = "inline",
      })
    end
    if data.type == "add" then
      apply_line_hl(buf, row, "CodeReviewDiffAdd")
      -- Word diff against previous delete if adjacent
      if prev_delete_row == row - 1 and prev_delete_text then
        local segments = parser.word_diff(prev_delete_text, data.item.text or "")
        for _, seg in ipairs(segments) do
          apply_word_hl(buf, prev_delete_row, seg.old_start, seg.old_end, "CodeReviewDiffDeleteWord")
          apply_word_hl(buf, row, seg.new_start, seg.new_end, "CodeReviewDiffAddWord")
        end
      end
      prev_delete_row = nil
      prev_delete_text = nil
    elseif data.type == "delete" then
      apply_line_hl(buf, row, "CodeReviewDiffDelete")
      prev_delete_row = row
      prev_delete_text = data.item.text or ""
    else
      prev_delete_row = nil
      prev_delete_text = nil
    end
  end

  -- Carrier lines: overlay with thread border so they don't show as empty rows
  for i, data in ipairs(line_data) do
    if data.type == "carrier" then
      vim.api.nvim_buf_set_extmark(buf, DIFF_NS, i - 1, 0, {
        virt_text = { { "    \xe2\x94\x83", "CodeReviewCommentBorder" } },
        virt_text_pos = "overlay",
      })
    end
  end

  place_hunk_separators(buf, line_data, false, file_line_count)

  local row_discussions = {}
  if discussions then
    row_discussions = M.place_comment_signs(
      buf,
      line_data,
      discussions,
      file_diff,
      row_selection,
      current_user,
      review,
      editing_note
    ) or {}
  end

  local row_ai = {}
  if ai_suggestions then
    row_ai = M.place_ai_suggestions(buf, line_data, ai_suggestions, file_diff, row_selection) or {}
  end

  return line_data, row_discussions, row_ai
end

-- ─── All-files scroll view ────────────────────────────────────────────────────

--- Build a map of file path -> discussions[] for O(1) lookup.
--- Handles both current and outdated (change_position) paths.
local function index_discussions_by_path(discussions, review)
  local by_path = {}
  for _, disc in ipairs(discussions or {}) do
    local note = disc.notes and disc.notes[1]
    if not note or not note.position then
      goto continue
    end
    local path
    if is_outdated(disc, review) and note.change_position then
      local cp = note.change_position
      path = cp.new_path or cp.old_path
    else
      local pos = note.position
      path = pos.new_path or pos.old_path
    end
    if path then
      by_path[path] = by_path[path] or {}
      table.insert(by_path[path], disc)
    end
    ::continue::
  end
  return by_path
end

function M.render_all_files(
  buf,
  files,
  review,
  discussions,
  context,
  file_contexts,
  ai_suggestions,
  row_selection,
  current_user,
  editing_note,
  diff_cache,
  commit_filter
)
  local parser = require("codereview.mr.diff_parser")
  context = context or config.get().diff.context
  file_contexts = file_contexts or {}

  local base_sha = commit_filter and commit_filter.from_sha or review.base_sha
  local head_sha = commit_filter and commit_filter.to_sha or review.head_sha
  local filter_suffix = commit_filter and (":" .. commit_filter.from_sha .. ".." .. commit_filter.to_sha) or ""

  local all_lines = {}
  local all_line_data = {}
  local file_sections = {}

  -- Batch git diff: collect uncached paths sharing the global context and fetch in one call
  if base_sha and head_sha and diff_cache then
    local uncached_paths = {}
    for file_idx, file_diff in ipairs(files) do
      local fpath = file_diff.new_path or file_diff.old_path
      local file_ctx = file_contexts[file_idx] or context
      local cache_key = fpath and (fpath .. ":" .. file_ctx .. filter_suffix) or nil
      if fpath and file_ctx == context and not (cache_key and diff_cache[cache_key]) then
        table.insert(uncached_paths, fpath)
      end
    end
    if #uncached_paths > 0 then
      local cmd = { "git", "diff", "-U" .. context, base_sha, head_sha, "--" }
      for _, p in ipairs(uncached_paths) do
        table.insert(cmd, p)
      end
      local result = vim.fn.system(cmd)
      if vim.v.shell_error == 0 and result ~= "" then
        local batch = parser.parse_batch_diff(result)
        for path, diff_text in pairs(batch) do
          local cache_key = path .. ":" .. context .. filter_suffix
          if not diff_cache[cache_key] then
            local hunks = parser.parse_hunks(diff_text)
            local display = parser.build_display(hunks, context)
            diff_cache[cache_key] = { hunks = hunks, display = display }
          end
        end
      end
    end
  end

  -- Pre-compute carrier line counts for scroll mode: "file_idx:line" -> carrier count
  local disc_by_path_scroll = index_discussions_by_path(discussions, review)
  local disc_carrier_counts_scroll = {}
  for fi, fd in ipairs(files) do
    local fpath = fd.new_path or fd.old_path
    for _, disc in ipairs(disc_by_path_scroll[fpath] or {}) do
      local target_line = discussion_line(disc, review)
      if target_line then
        local non_system_count = 0
        for _, note in ipairs(disc.notes or {}) do
          if not note.system then
            non_system_count = non_system_count + 1
          end
        end
        local carriers = math.max(0, non_system_count - 1)
        if carriers > 0 then
          local key = fi .. ":" .. target_line
          disc_carrier_counts_scroll[key] = (disc_carrier_counts_scroll[key] or 0) + carriers
        end
      end
    end
  end

  for file_idx, file_diff in ipairs(files) do
    local section_start = #all_lines + 1

    -- File header separator
    local path = file_diff.new_path or file_diff.old_path or "unknown"
    local label = path
    if file_diff.renamed_file then
      label = (file_diff.old_path or "") .. " → " .. (file_diff.new_path or "")
    elseif file_diff.new_file then
      label = path .. " (new file)"
    elseif file_diff.deleted_file then
      label = path .. " (deleted)"
    end
    local header = "─── " .. label .. " " .. string.rep("─", math.max(0, 60 - #label - 5))
    table.insert(all_lines, header)
    table.insert(all_line_data, { type = "file_header", file_idx = file_idx })

    -- Parse and build display for this file (per-file context overrides global)
    local file_ctx = file_contexts[file_idx] or context
    local fpath = file_diff.new_path or file_diff.old_path
    local cache_key = fpath and (fpath .. ":" .. file_ctx .. filter_suffix) or nil
    local file_cached = diff_cache and cache_key and diff_cache[cache_key]

    local display, hunks, file_line_count
    if file_cached then
      display = file_cached.display
      hunks = file_cached.hunks
      file_line_count = file_cached.file_line_count
    else
      local diff_text = file_diff.diff or ""
      if base_sha and head_sha and fpath then
        local result = vim.fn.system({
          "git",
          "diff",
          "-U" .. file_ctx,
          base_sha,
          head_sha,
          "--",
          fpath,
        })
        -- Only fetch missing objects when user explicitly changed context
        if vim.v.shell_error ~= 0 and file_ctx ~= context then
          M.ensure_git_objects(base_sha, head_sha)
          result = vim.fn.system({
            "git",
            "diff",
            "-U" .. file_ctx,
            base_sha,
            head_sha,
            "--",
            fpath,
          })
        end
        if vim.v.shell_error == 0 and result ~= "" then
          diff_text = result
        end
      end
      hunks = parser.parse_hunks(diff_text)
      display = parser.build_display(hunks, file_ctx)

      -- Get file line count for BOF/EOF detection
      if fpath and head_sha then
        local wc = vim.fn.system({ "git", "show", head_sha .. ":" .. fpath })
        if vim.v.shell_error == 0 then
          file_line_count = select(2, wc:gsub("\n", "\n"))
        end
      end

      if diff_cache and cache_key then
        diff_cache[cache_key] = { hunks = hunks, display = display, file_line_count = file_line_count }
      end
    end

    if #display == 0 then
      table.insert(all_lines, "  (no changes)")
      table.insert(all_line_data, { type = "empty", file_idx = file_idx })
    else
      for _, item in ipairs(display) do
        if item.type ~= "hunk_boundary" then
          table.insert(all_lines, item.text or "")
          table.insert(all_line_data, { type = item.type, item = item, file_idx = file_idx })
          local target = item.new_line or item.old_line
          local key = target and (file_idx .. ":" .. target)
          local carrier_count = key and disc_carrier_counts_scroll[key] or 0
          for k = 1, carrier_count do
            table.insert(all_lines, "")
            table.insert(
              all_line_data,
              { type = "carrier", file_idx = file_idx, anchor_line = target, carrier_idx = k }
            )
          end
        end
      end
      -- trim trailing empty-text context lines (parser artifact from trailing \n)
      while
        #all_lines > section_start
        and all_lines[#all_lines] == ""
        and all_line_data[#all_line_data].type ~= "carrier"
      do
        table.remove(all_lines)
        table.remove(all_line_data)
      end
    end

    local section_end = #all_lines

    -- Blank line between files (except after last)
    if file_idx < #files then
      table.insert(all_lines, "")
      table.insert(all_line_data, { type = "separator", file_idx = file_idx })
    end

    -- BOF/EOF detection for edge separators
    local at_bof = #hunks > 0 and hunks[1].new_start <= 1 and hunks[1].old_start <= 1
    local at_eof = false
    if file_line_count and #display > 0 then
      for i = #display, 1, -1 do
        if display[i].new_line then
          at_eof = display[i].new_line >= file_line_count
          break
        end
      end
    end

    table.insert(file_sections, {
      start_line = section_start,
      end_line = section_end,
      file_idx = file_idx,
      file = file_diff,
      at_bof = at_bof,
      at_eof = at_eof,
    })
  end

  -- Set buffer content
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  vim.bo[buf].modifiable = false

  -- Clear previous highlights
  vim.api.nvim_buf_clear_namespace(buf, DIFF_NS, 0, -1)

  -- Apply extmarks
  local prev_delete_row = nil
  local prev_delete_text = nil

  for i, data in ipairs(all_line_data) do
    local row = i - 1
    if data.item and (data.item.old_line or data.item.new_line) then
      vim.api.nvim_buf_set_extmark(buf, DIFF_NS, row, 0, {
        virt_text = { { M.format_line_number(data.item.old_line, data.item.new_line), "CodeReviewLineNr" } },
        virt_text_pos = "inline",
      })
    end
    if data.type == "file_header" then
      apply_line_hl(buf, row, "CodeReviewFileHeader")
      prev_delete_row = nil
      prev_delete_text = nil
    elseif data.type == "add" then
      apply_line_hl(buf, row, "CodeReviewDiffAdd")
      if prev_delete_row == row - 1 and prev_delete_text then
        local segments = parser.word_diff(prev_delete_text, data.item.text or "")
        for _, seg in ipairs(segments) do
          apply_word_hl(buf, prev_delete_row, seg.old_start, seg.old_end, "CodeReviewDiffDeleteWord")
          apply_word_hl(buf, row, seg.new_start, seg.new_end, "CodeReviewDiffAddWord")
        end
      end
      prev_delete_row = nil
      prev_delete_text = nil
    elseif data.type == "delete" then
      apply_line_hl(buf, row, "CodeReviewDiffDelete")
      prev_delete_row = row
      prev_delete_text = data.item.text or ""
    else
      prev_delete_row = nil
      prev_delete_text = nil
    end
  end

  -- Apply Vim syntax highlighting per file section using syntax include/region
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("syntax clear")
    local loaded_fts = {}
    for _, section in ipairs(file_sections) do
      local fpath = section.file.new_path or section.file.old_path
      if fpath then
        local ft = vim.filetype.match({ filename = fpath })
        if ft then
          local cluster = "GlabSyn_" .. ft:gsub("[^%w]", "_")
          if not loaded_fts[ft] then
            vim.cmd("unlet! b:current_syntax")
            if syntax_file_cache[ft] == nil then
              local syn_files = vim.api.nvim_get_runtime_file("syntax/" .. ft .. ".vim", false)
              syntax_file_cache[ft] = (syn_files and syn_files[1]) or false
            end
            local syn_file = syntax_file_cache[ft]
            if syn_file then
              pcall(vim.cmd, "syntax include @" .. cluster .. " " .. vim.fn.fnameescape(syn_file))
              loaded_fts[ft] = cluster
            end
          end
          if loaded_fts[ft] then
            -- Create sub-regions that skip delete lines to prevent syntax state corruption
            local content_start = section.start_line + 1
            local content_end = section.end_line
            local span_start = nil
            local region_idx = 0
            for i = content_start, content_end do
              if all_line_data[i] and all_line_data[i].type == "delete" then
                if span_start then
                  region_idx = region_idx + 1
                  pcall(
                    vim.cmd,
                    string.format(
                      'syntax region GlabRegion_%d_%d start="\\%%%dl" end="\\%%%dl" contains=@%s keepend',
                      section.file_idx,
                      region_idx,
                      span_start,
                      i - 1,
                      loaded_fts[ft]
                    )
                  )
                  span_start = nil
                end
              else
                if not span_start then
                  span_start = i
                end
              end
            end
            if span_start then
              region_idx = region_idx + 1
              pcall(
                vim.cmd,
                string.format(
                  'syntax region GlabRegion_%d_%d start="\\%%%dl" end="\\%%%dl" contains=@%s keepend',
                  section.file_idx,
                  region_idx,
                  span_start,
                  content_end,
                  loaded_fts[ft]
                )
              )
            end
          end
        end
      end
    end
  end)

  -- Carrier lines: overlay with thread border so they don't show as empty rows
  for i, data in ipairs(all_line_data) do
    if data.type == "carrier" then
      vim.api.nvim_buf_set_extmark(buf, DIFF_NS, i - 1, 0, {
        virt_text = { { "    \xe2\x94\x83", "CodeReviewCommentBorder" } },
        virt_text_pos = "overlay",
      })
    end
  end

  place_hunk_separators(buf, all_line_data, true)

  -- Edge separators for scroll mode: top/bottom of each file section
  do
    local cfg_sep = config.get().diff
    if cfg_sep.separator_lines > 0 and cfg_sep.separator_char ~= "" then
      local win_w = 80
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == buf then
          win_w = vim.api.nvim_win_get_width(w)
          break
        end
      end
      local keymaps = require("codereview.keymaps")
      local toggle_key = keymaps.get("toggle_full_file") or "<C-f>"
      local plain = { { string.rep(cfg_sep.separator_char, win_w), "CodeReviewHunkSeparator" } }

      local function edge_hint(arrow)
        local txt = " " .. arrow .. " Press " .. toggle_key .. " to show full file " .. arrow .. " "
        local rem = win_w - vim.fn.strdisplaywidth(txt)
        if rem >= 2 then
          local l = math.floor(rem / 2)
          return {
            { string.rep(cfg_sep.separator_char, l), "CodeReviewHunkSeparator" },
            { txt, "CodeReviewHunkSeparatorHint" },
            { string.rep(cfg_sep.separator_char, rem - l), "CodeReviewHunkSeparator" },
          }
        end
        return plain
      end

      for _, section in ipairs(file_sections) do
        -- Top edge: below file_header when not at BOF
        if not section.at_bof and section.start_line < section.end_line then
          vim.api.nvim_buf_set_extmark(buf, SEPARATOR_NS, section.start_line - 1, 0, {
            virt_lines = { edge_hint("▲"), plain },
            virt_lines_above = false,
          })
        end
        -- Bottom edge: below last content line when not at EOF
        if not section.at_eof and section.end_line >= section.start_line then
          vim.api.nvim_buf_set_extmark(buf, SEPARATOR_NS, section.end_line - 1, 0, {
            virt_lines = { plain, edge_hint("▼") },
            virt_lines_above = false,
          })
        end
      end
    end
  end

  -- Build scroll lookup map once for O(1) comment and suggestion placement
  local scroll_map = M.build_line_to_row_scroll(all_line_data)

  -- Place comment signs and inline threads per file section
  local all_row_discussions = {}
  local disc_by_path = index_discussions_by_path(discussions, review)
  -- Per-anchor carrier offset: tracks how many carrier rows earlier discussions have consumed
  local scroll_carrier_offsets = {}
  for _, section in ipairs(file_sections) do
    local fpath = section.file.new_path or section.file.old_path
    for _, disc in ipairs(disc_by_path[fpath] or {}) do
      local target_line, range_start, disc_outdated = discussion_line(disc, review)
      if target_line then
        local sign_name = is_resolved(disc) and "CodeReviewCommentSign" or "CodeReviewUnresolvedSign"
        local file_prefix = section.file_idx .. ":"
        -- Place signs on range lines using O(1) lookups
        if range_start and range_start ~= target_line then
          for ln = range_start, target_line - 1 do
            local i = scroll_map[file_prefix .. ln]
            if i then
              pcall(vim.fn.sign_place, 0, "CodeReview", sign_name, buf, { lnum = i })
            end
          end
        end
        -- Find the end-line row for the inline thread (O(1) lookup)
        local i = scroll_map[file_prefix .. target_line]
        if i then
          -- Place sign (also covers single-line comments)
          pcall(vim.fn.sign_place, 0, "CodeReview", sign_name, buf, { lnum = i })

          local notes = disc.notes
          if notes and #notes > 0 then
            local sel = row_selection and row_selection[i]
            local sel_idx = sel and sel.type == "comment" and sel.disc_id == disc.id and sel.note_idx or nil
            local result = tvl.build(disc, {
              sel_idx = sel_idx,
              current_user = current_user,
              outdated = disc_outdated,
              editing_note = editing_note,
              spacer_height = editing_note and editing_note.spacer_height or 0,
              gutter = 4,
            })
            local carriers = find_carrier_rows(all_line_data, i)
            local offset = scroll_carrier_offsets[i] or 0
            local segments = result.note_segments or { result }
            for seg_i, seg in ipairs(segments) do
              local target_row = (seg_i == 1) and i or carriers[offset + seg_i - 1]
              if target_row and #seg.virt_lines > 0 then
                pcall(vim.api.nvim_buf_set_extmark, buf, DIFF_NS, target_row - 1, 0, {
                  virt_lines = seg.virt_lines,
                  virt_lines_above = false,
                })
              end
            end
            scroll_carrier_offsets[i] = offset + math.max(0, #segments - 1)
          end

          if not all_row_discussions[i] then
            all_row_discussions[i] = {}
          end
          table.insert(all_row_discussions[i], disc)
        end
      end
    end
  end

  local all_row_ai = {}
  if ai_suggestions then
    all_row_ai = M.place_ai_suggestions_all(
      buf,
      all_line_data,
      file_sections,
      ai_suggestions,
      row_selection,
      scroll_map
    ) or {}
  end

  return {
    file_sections = file_sections,
    line_data = all_line_data,
    row_discussions = all_row_discussions,
    row_ai = all_row_ai,
  }
end

return M
