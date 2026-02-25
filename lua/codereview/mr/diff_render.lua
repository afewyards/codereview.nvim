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
local LINE_NR_WIDTH = 14  -- luacheck: ignore
local COMMENT_PAD = string.rep(" ", 4)

-- nvim_create_namespace returns the same ID for the same name — safe to declare
-- in multiple modules.
local DIFF_NS = vim.api.nvim_create_namespace("codereview_diff")
local AIDRAFT_NS = vim.api.nvim_create_namespace("codereview_ai_draft")

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
  if col_start >= col_end then return end
  vim.api.nvim_buf_set_extmark(buf, DIFF_NS, row, col_start, {
    end_col = col_end,
    hl_group = hl_group,
  })
end

-- Export for use in diff.lua (sidebar renderer needs these)
M.apply_line_hl = apply_line_hl
M.apply_word_hl = apply_word_hl

-- ─── Discussion helpers ───────────────────────────────────────────────────────

local function is_outdated(discussion, review)
  local note = discussion.notes and discussion.notes[1]
  if not note then return false end
  if note.position and note.position.outdated then return true end
  if not review or not review.head_sha then return false end
  if not note.position or not note.position.head_sha then return false end
  return note.position.head_sha ~= review.head_sha
end

local function discussion_matches_file(discussion, file_diff, review)
  local note = discussion.notes and discussion.notes[1]
  if not note or not note.position then return false end
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
  if not note or not note.position then return nil end
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
    local header_label = drafted
      and (" ◆ AI · " .. severity .. " ✓ drafted ")
      or (" ◆ AI · " .. severity .. " ")
    local header_fill = math.max(0, 62 - #header_label)

    local sel_pre = is_selected and "██  " or COMMENT_PAD  -- luacheck: ignore
    local sel_blk = is_selected and { "██", ai_status_hl } or nil

    -- Header line
    local header_line = {}
    if sel_blk then table.insert(header_line, sel_blk) end
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

function M.place_comment_signs(buf, line_data, discussions, file_diff, row_selection, current_user, review, editing_note, line_to_row)
  -- Remove old signs for this buffer
  pcall(vim.fn.sign_unplace, "CodeReview", { buffer = buf })

  -- Track which rows have discussions (for keymap lookups)
  local row_discussions = {}
  local map = line_to_row or M.build_line_to_row(line_data)

  for _, discussion in ipairs(discussions or {}) do
    if discussion_matches_file(discussion, file_diff, review) then
      local target_line, range_start, outdated = discussion_line(discussion, review)
      if target_line then
        local sign_name = is_resolved(discussion) and "CodeReviewCommentSign"
          or "CodeReviewUnresolvedSign"
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

          -- Render full comment thread inline
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
            pcall(vim.api.nvim_buf_set_extmark, buf, DIFF_NS, row - 1, 0, {
              virt_lines = result.virt_lines,
              virt_lines_above = false,
            })
          end

          -- Store discussion for this row
          if not row_discussions[row] then row_discussions[row] = {} end
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
          if not row_ai_map[matched_row] then row_ai_map[matched_row] = {} end
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
            if not scroll_row_ai[matched_row] then scroll_row_ai[matched_row] = {} end
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

function M.render_file_diff(buf, file_diff, review, discussions, context, ai_suggestions, row_selection, current_user, editing_note)
  local parser = require("codereview.mr.diff_parser")
  if not context then
    context = config.get().diff.context
  end

  -- Try local git diff with more context lines; fall back to API diff
  local diff_text = file_diff.diff or ""
  if review.base_sha and review.head_sha then
    local path = file_diff.new_path or file_diff.old_path
    if path then
      local result = vim.fn.system({
        "git", "diff",
        "-U" .. context,
        review.base_sha,
        review.head_sha,
        "--", path,
      })
      if vim.v.shell_error == 0 and result ~= "" then
        diff_text = result
      end
    end
  end

  local hunks = parser.parse_hunks(diff_text)
  local display = parser.build_display(hunks, 99999)

  -- Get file line count for BOF/EOF detection
  local file_line_count
  local file_path = file_diff.new_path or file_diff.old_path
  if file_path and review.head_sha then
    local wc = vim.fn.system({
      "git", "show", review.head_sha .. ":" .. file_path,
    })
    if vim.v.shell_error == 0 then
      file_line_count = select(2, wc:gsub("\n", "\n"))
    end
  end

  local lines = {}
  local line_data = {}

  -- "Load more above" — only if first hunk doesn't start at line 1
  local starts_at_bof = #hunks > 0 and hunks[1].new_start <= 1 and hunks[1].old_start <= 1
  if #hunks > 0 and not starts_at_bof then
    table.insert(lines, "  ↑ Press <CR> to load more context above ↑")
    table.insert(line_data, { type = "load_more", direction = "above" })
  end

  for _, item in ipairs(display) do
    table.insert(lines, item.text or "")
    table.insert(line_data, { type = item.type, item = item })
  end

  -- "Load more below" — only if last displayed line doesn't reach EOF
  local at_eof = false
  if file_line_count and #display > 0 then
    for i = #display, 1, -1 do
      if display[i].new_line then
        at_eof = display[i].new_line >= file_line_count
        break
      end
    end
  end
  if #hunks > 0 and not at_eof then
    table.insert(lines, "  ↓ Press <CR> to load more context below ↓")
    table.insert(line_data, { type = "load_more", direction = "below" })
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
          apply_word_hl(buf, prev_delete_row,
            seg.old_start, seg.old_end,
            "CodeReviewDiffDeleteWord")
          apply_word_hl(buf, row,
            seg.new_start, seg.new_end,
            "CodeReviewDiffAddWord")
        end
      end
      prev_delete_row = nil
      prev_delete_text = nil
    elseif data.type == "delete" then
      apply_line_hl(buf, row, "CodeReviewDiffDelete")
      prev_delete_row = row
      prev_delete_text = data.item.text or ""
    elseif data.type == "load_more" then
      apply_line_hl(buf, row, "CodeReviewHidden")
      prev_delete_row = nil
      prev_delete_text = nil
    else
      prev_delete_row = nil
      prev_delete_text = nil
    end
  end

  local row_discussions = {}
  if discussions then
    row_discussions = M.place_comment_signs(buf, line_data, discussions, file_diff, row_selection, current_user, review, editing_note) or {}
  end

  local row_ai = {}
  if ai_suggestions then
    row_ai = M.place_ai_suggestions(buf, line_data, ai_suggestions, file_diff, row_selection) or {}
  end

  return line_data, row_discussions, row_ai
end

-- ─── All-files scroll view ────────────────────────────────────────────────────

function M.render_all_files(buf, files, review, discussions, context, file_contexts, ai_suggestions, row_selection, current_user, editing_note)
  local parser = require("codereview.mr.diff_parser")
  context = context or config.get().diff.context
  file_contexts = file_contexts or {}

  local all_lines = {}
  local all_line_data = {}
  local file_sections = {}

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
    local diff_text = file_diff.diff or ""
    if review.base_sha and review.head_sha then
      local fpath = file_diff.new_path or file_diff.old_path
      if fpath then
        local result = vim.fn.system({
          "git", "diff", "-U" .. file_ctx,
          review.base_sha, review.head_sha, "--", fpath,
        })
        if vim.v.shell_error == 0 and result ~= "" then
          diff_text = result
        end
      end
    end

    local hunks = parser.parse_hunks(diff_text)
    local display = parser.build_display(hunks, file_ctx)

    if #display == 0 then
      table.insert(all_lines, "  (no changes)")
      table.insert(all_line_data, { type = "empty", file_idx = file_idx })
    else
      for _, item in ipairs(display) do
        table.insert(all_lines, item.text or "")
        table.insert(all_line_data, { type = item.type, item = item, file_idx = file_idx })
      end
      -- trim trailing empty-text context lines (parser artifact from trailing \n)
      while #all_lines > section_start and all_lines[#all_lines] == "" do
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

    table.insert(file_sections, {
      start_line = section_start,
      end_line = section_end,
      file_idx = file_idx,
      file = file_diff,
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
          apply_word_hl(buf, prev_delete_row,
            seg.old_start, seg.old_end,
            "CodeReviewDiffDeleteWord")
          apply_word_hl(buf, row,
            seg.new_start, seg.new_end,
            "CodeReviewDiffAddWord")
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
            local syn_files = vim.api.nvim_get_runtime_file("syntax/" .. ft .. ".vim", false)
            if syn_files and #syn_files > 0 then
              pcall(vim.cmd, "syntax include @" .. cluster .. " " .. vim.fn.fnameescape(syn_files[1]))
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
                  pcall(vim.cmd, string.format(
                    'syntax region GlabRegion_%d_%d start="\\%%%dl" end="\\%%%dl" contains=@%s keepend',
                    section.file_idx, region_idx, span_start, i - 1, loaded_fts[ft]
                  ))
                  span_start = nil
                end
              else
                if not span_start then span_start = i end
              end
            end
            if span_start then
              region_idx = region_idx + 1
              pcall(vim.cmd, string.format(
                'syntax region GlabRegion_%d_%d start="\\%%%dl" end="\\%%%dl" contains=@%s keepend',
                section.file_idx, region_idx, span_start, content_end, loaded_fts[ft]
              ))
            end
          end
        end
      end
    end
  end)

  -- Build scroll lookup map once for O(1) comment and suggestion placement
  local scroll_map = M.build_line_to_row_scroll(all_line_data)

  -- Place comment signs and inline threads per file section
  local all_row_discussions = {}
  for _, section in ipairs(file_sections) do
    for _, disc in ipairs(discussions or {}) do
      if discussion_matches_file(disc, section.file, review) then
        local target_line, range_start, disc_outdated = discussion_line(disc, review)
        if target_line then
          local sign_name = is_resolved(disc) and "CodeReviewCommentSign"
            or "CodeReviewUnresolvedSign"
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
              pcall(vim.api.nvim_buf_set_extmark, buf, DIFF_NS, i - 1, 0, {
                virt_lines = result.virt_lines, virt_lines_above = false,
              })
            end

            if not all_row_discussions[i] then all_row_discussions[i] = {} end
            table.insert(all_row_discussions[i], disc)
          end
        end
      end
    end
  end

  local all_row_ai = {}
  if ai_suggestions then
    all_row_ai = M.place_ai_suggestions_all(buf, all_line_data, file_sections, ai_suggestions, row_selection, scroll_map) or {}
  end

  return {
    file_sections = file_sections,
    line_data = all_line_data,
    row_discussions = all_row_discussions,
    row_ai = all_row_ai,
  }
end

return M
