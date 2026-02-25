local M = {}
local config = require("codereview.config")
local markdown = require("codereview.ui.markdown")
local tvl = require("codereview.mr.thread_virt_lines")
local wrap_text = tvl.wrap_text
local md_virt_line = tvl.md_virt_line
local is_resolved = tvl.is_resolved

-- LINE_NR_WIDTH: "%5d | %-5d " = 5+3+5+1 = 14 chars
local LINE_NR_WIDTH = 14
local COMMENT_PAD = string.rep(" ", 4)

local DIFF_NS = vim.api.nvim_create_namespace("codereview_diff")
local AIDRAFT_NS = vim.api.nvim_create_namespace("codereview_ai_draft")
local SUMMARY_NS = vim.api.nvim_create_namespace("codereview_summary")


-- ─── Active state tracking ────────────────────────────────────────────────────

local active_states = {}

function M.get_state(buf)
  return active_states[buf]
end

--- Build ordered list of selectable items at a row.
--- @param ai_suggestions table[] array of AI suggestions at this row
--- @param discussions table[] array of discussions at this row
--- @return table[] items ordered: AI first, then comment notes
function M.build_row_items(ai_suggestions, discussions)
  local items = {}
  for i = 1, #ai_suggestions do
    table.insert(items, { type = "ai", index = i })
  end
  for _, disc in ipairs(discussions) do
    for ni, note in ipairs(disc.notes or {}) do
      if not note.system then
        table.insert(items, { type = "comment", disc_id = disc.id, note_idx = ni })
      end
    end
  end
  return items
end

--- Cycle through row items.
--- @param items table[] from build_row_items
--- @param current table|nil current selection
--- @param direction number +1 forward, -1 backward
--- @return table|nil next selection
function M.cycle_row_selection(items, current, direction)
  if #items == 0 then return nil end
  if not current then
    return direction > 0 and items[1] or items[#items]
  end
  -- Find current position
  local pos
  for i, item in ipairs(items) do
    if item.type == current.type then
      if item.type == "ai" and item.index == current.index then
        pos = i; break
      elseif item.type == "comment" and item.disc_id == current.disc_id and item.note_idx == current.note_idx then
        pos = i; break
      end
    end
  end
  if not pos then return direction > 0 and items[1] or items[#items] end
  local next_pos = pos + direction
  if next_pos < 1 or next_pos > #items then return nil end
  return items[next_pos]
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
  if col_start >= col_end then return end
  vim.api.nvim_buf_set_extmark(buf, DIFF_NS, row, col_start, {
    end_col = col_end,
    hl_group = hl_group,
  })
end

-- ─── Sign helpers ─────────────────────────────────────────────────────────────

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

function M.place_comment_signs(buf, line_data, discussions, file_diff, row_selection, current_user, review, editing_note)
  -- Remove old signs for this buffer
  pcall(vim.fn.sign_unplace, "CodeReview", { buffer = buf })

  -- Track which rows have discussions (for keymap lookups)
  local row_discussions = {}

  for _, discussion in ipairs(discussions or {}) do
    if discussion_matches_file(discussion, file_diff, review) then
      local target_line, range_start, outdated = discussion_line(discussion, review)
      if target_line then
        local sign_name = is_resolved(discussion) and "CodeReviewCommentSign"
          or "CodeReviewUnresolvedSign"
        -- Place signs on all lines in the range (visual only; navigation uses target_line)
        if range_start and range_start ~= target_line then
          for row, data in ipairs(line_data) do
            local item = data.item
            if item then
              local ln = tonumber(item.new_line) or tonumber(item.old_line)
              if ln and ln >= range_start and ln < target_line then
                pcall(vim.fn.sign_place, 0, "CodeReview", sign_name, buf, { lnum = row })
              end
            end
          end
        end
        -- Find the end-line row for the inline thread
        for row, data in ipairs(line_data) do
          local item = data.item
          if item and (item.new_line == target_line or item.old_line == target_line) then
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
            break
          end
        end
      end
    end
  end

  return row_discussions
end

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

    local sel_pre = is_selected and "██  " or COMMENT_PAD
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

function M.place_ai_suggestions(buf, line_data, suggestions, file_diff, row_selection)
  -- Clear old AI signs and extmarks
  pcall(vim.fn.sign_unplace, "CodeReviewAI", { buffer = buf })
  vim.api.nvim_buf_clear_namespace(buf, AIDRAFT_NS, 0, -1)

  local row_ai_map = {}

  -- Pass 1: gather suggestions into row_ai_map (no rendering)
  for _, suggestion in ipairs(suggestions or {}) do
    if suggestion.status ~= "dismissed" then
      local path = file_diff.new_path or file_diff.old_path
      if suggestion.file == path then
        local matched_row = nil
        for row, data in ipairs(line_data) do
          if data.item and data.item.new_line == suggestion.line then
            matched_row = row
            break
          end
        end
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

function M.place_ai_suggestions_all(buf, all_line_data, file_sections, suggestions, row_selection)
  -- Clear old AI signs and extmarks
  pcall(vim.fn.sign_unplace, "CodeReviewAI", { buffer = buf })
  vim.api.nvim_buf_clear_namespace(buf, AIDRAFT_NS, 0, -1)

  local scroll_row_ai = {}

  -- Pass 1: gather suggestions into scroll_row_ai (no rendering)
  for _, suggestion in ipairs(suggestions or {}) do
    if suggestion.status ~= "dismissed" then
      for _, section in ipairs(file_sections) do
        local fpath = section.file.new_path or section.file.old_path
        if suggestion.file == fpath then
          local matched_row = nil
          for i = section.start_line, section.end_line do
            local data = all_line_data[i]
            if data and data.item and data.item.new_line == suggestion.line
              and data.file_idx == section.file_idx then
              matched_row = i
              break
            end
          end
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

  -- Place comment signs and inline threads per file section
  local all_row_discussions = {}
  for _, section in ipairs(file_sections) do
    for _, disc in ipairs(discussions or {}) do
      if discussion_matches_file(disc, section.file, review) then
        local target_line, range_start, disc_outdated = discussion_line(disc, review)
        if target_line then
          local sign_name = is_resolved(disc) and "CodeReviewCommentSign"
            or "CodeReviewUnresolvedSign"
          -- Place signs on range lines (visual only; navigation uses target_line)
          if range_start and range_start ~= target_line then
            for i = section.start_line, section.end_line do
              local data = all_line_data[i]
              if data.item then
                local ln = tonumber(data.item.new_line) or tonumber(data.item.old_line)
                if ln and ln >= range_start and ln < target_line then
                  pcall(vim.fn.sign_place, 0, "CodeReview", sign_name, buf, { lnum = i })
                end
              end
            end
          end
          -- Find the end-line row for the inline thread
          for i = section.start_line, section.end_line do
            local data = all_line_data[i]
            if data.item and (data.item.new_line == target_line or data.item.old_line == target_line) then
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
              break
            end
          end
        end
      end
    end
  end

  local all_row_ai = {}
  if ai_suggestions then
    all_row_ai = M.place_ai_suggestions_all(buf, all_line_data, file_sections, ai_suggestions, row_selection) or {}
  end

  return {
    file_sections = file_sections,
    line_data = all_line_data,
    row_discussions = all_row_discussions,
    row_ai = all_row_ai,
  }
end

-- ─── Summary rendering ──────────────────────────────────────────────────────

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

-- ─── Sidebar rendering ────────────────────────────────────────────────────────

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

-- ─── Comment creation ─────────────────────────────────────────────────────────

function M.create_comment_at_cursor(layout, state, optimistic)
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
  local built_opt = optimistic and {
    add = optimistic.add(file.old_path, file.new_path, data.item.old_line, data.item.new_line),
    remove = optimistic.remove,
    mark_failed = optimistic.mark_failed,
    refresh = optimistic.refresh,
  } or nil
  local comment = require("codereview.mr.comment")
  comment.create_inline(
    state.review,
    file.old_path,
    file.new_path,
    data.item.old_line,
    data.item.new_line,
    built_opt,
    { anchor_line = row, win_id = layout.main_win, action_type = "comment", context_text = line_text }
  )
end

function M.create_comment_range(layout, state, optimistic)
  local line_data = state.line_data_cache[state.current_file]
  if not line_data then return end
  -- Get visual selection range
  local s, e = vim.fn.line("v"), vim.fn.line(".")
  if s > e then s, e = e, s end
  local start_data = line_data[s]
  local end_data = line_data[e]
  if not start_data or not end_data then
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
  local built_opt = optimistic and {
    add = optimistic.add(file.old_path, file.new_path, end_data.item.old_line, end_data.item.new_line, start_data.item.new_line),
    remove = optimistic.remove,
    mark_failed = optimistic.mark_failed,
    refresh = optimistic.refresh,
  } or nil
  local comment = require("codereview.mr.comment")
  comment.create_inline_range(
    state.review,
    file.old_path,
    file.new_path,
    { old_line = start_data.item.old_line, new_line = start_data.item.new_line },
    { old_line = end_data.item.old_line, new_line = end_data.item.new_line },
    built_opt,
    { anchor_line = e, anchor_start = s, win_id = layout.main_win, action_type = "comment", context_text = line_text }
  )
end

-- ─── Navigation helpers ───────────────────────────────────────────────────────

local function nav_file(layout, state, delta)
  local files = state.files or {}
  local next_idx = state.current_file + delta
  if next_idx < 1 or next_idx > #files then return end
  state.current_file = next_idx
  state.row_selection = {}
  M.render_sidebar(layout.sidebar_buf, state)
  local line_data, row_disc, row_ai = M.render_file_diff(layout.main_buf, files[next_idx], state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user)
  state.line_data_cache[next_idx] = line_data
  state.row_disc_cache[next_idx] = row_disc
  state.row_ai_cache[next_idx] = row_ai
  vim.api.nvim_win_set_cursor(layout.main_win, { 1, 0 })
end

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

--- Check if a file has any annotations (discussions or AI suggestions) without relying on cache.
--- @param state table
--- @param file_idx number
--- @return boolean
function M.file_has_annotations(state, file_idx)
  local files = state.files or {}
  local file = files[file_idx]
  if not file then return false end
  for _, disc in ipairs(state.discussions or {}) do
    if discussion_matches_file(disc, file) then return true end
  end
  for _, sug in ipairs(state.ai_suggestions or {}) do
    if sug.file_path == file.new_path or sug.file_path == file.old_path then return true end
  end
  return false
end

local function switch_to_file(layout, state, idx)
  state.current_file = idx
  state.row_selection = {}
  M.render_sidebar(layout.sidebar_buf, state)
  local ld, rd, ra = M.render_file_diff(
    layout.main_buf, state.files[idx], state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user)
  state.line_data_cache[idx] = ld
  state.row_disc_cache[idx] = rd
  state.row_ai_cache[idx] = ra
end

function M.jump_to_file(layout, state, file_idx)
  if not state.files or not state.files[file_idx] then return end

  -- Transition out of summary mode into diff mode (mirrors sidebar click logic)
  if state.view_mode == "summary" then
    state.view_mode = "diff"
    state.current_file = file_idx
    vim.wo[layout.main_win].wrap = false
    vim.wo[layout.main_win].linebreak = false
    if state.scroll_mode then
      local result = M.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions)
      state.file_sections = result.file_sections
      state.scroll_line_data = result.line_data
      state.scroll_row_disc = result.row_discussions
      state.scroll_row_ai = result.row_ai
      M.render_sidebar(layout.sidebar_buf, state)
      for _, sec in ipairs(state.file_sections) do
        if sec.file_idx == file_idx then
          vim.api.nvim_win_set_cursor(layout.main_win, { sec.start_line, 0 })
          break
        end
      end
    else
      M.render_sidebar(layout.sidebar_buf, state)
      local ld, rd, ra = M.render_file_diff(
        layout.main_buf, state.files[file_idx], state.review, state.discussions, state.context, state.ai_suggestions)
      state.line_data_cache[file_idx] = ld
      state.row_disc_cache[file_idx] = rd
      state.row_ai_cache[file_idx] = ra
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
    switch_to_file(layout, state, file_idx)
    vim.api.nvim_win_set_cursor(layout.main_win, { 1, 0 })
  end
end

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
      switch_to_file(layout, state, entry.file_idx)
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

-- ─── Context adjustment ─────────────────────────────────────────────────────

local function adjust_context(layout, state, delta)
  local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
  state.context = math.max(1, state.context + delta)
  if state.scroll_mode then
    local anchor = M.find_anchor(state.scroll_line_data, cursor_row)
    local result = M.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user)
    state.file_sections = result.file_sections
    state.scroll_line_data = result.line_data
    state.scroll_row_disc = result.row_discussions
    state.scroll_row_ai = result.row_ai
    local row = M.find_row_for_anchor(state.scroll_line_data, anchor)
    vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
  else
    local per_file_ld = state.line_data_cache[state.current_file]
    local anchor = M.find_anchor(per_file_ld or {}, cursor_row, state.current_file)
    local file = state.files and state.files[state.current_file]
    if not file then return end
    local ld, row_disc, row_ai = M.render_file_diff(
      layout.main_buf, file, state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user)
    state.line_data_cache[state.current_file] = ld
    state.row_disc_cache[state.current_file] = row_disc
    state.row_ai_cache[state.current_file] = row_ai
    local row = M.find_row_for_anchor(ld, anchor, state.current_file)
    vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
  end
  vim.notify("Context: " .. state.context .. " lines", vim.log.levels.INFO)
end

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

-- ─── Scroll mode helpers ──────────────────────────────────────────────────────

local function current_file_from_cursor(layout, state)
  local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
  local row = cursor[1]
  for i = #state.file_sections, 1, -1 do
    if row >= state.file_sections[i].start_line then
      return state.file_sections[i].file_idx
    end
  end
  return 1
end

local function toggle_scroll_mode(layout, state)
  local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
  state.row_selection = {}

  if state.scroll_mode then
    -- EXITING scroll mode → per-file
    local anchor = M.find_anchor(state.scroll_line_data, cursor_row)
    state.current_file = anchor.file_idx
    state.scroll_mode = false

    local file = state.files[state.current_file]
    if file then
      local ld, rd, ra = M.render_file_diff(layout.main_buf, file, state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user)
      state.line_data_cache[state.current_file] = ld
      state.row_disc_cache[state.current_file] = rd
      state.row_ai_cache[state.current_file] = ra
      local row = M.find_row_for_anchor(ld, anchor, state.current_file)
      vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
    end
  else
    -- ENTERING scroll mode → all-files
    local per_file_ld = state.line_data_cache[state.current_file]
    local anchor = M.find_anchor(per_file_ld or {}, cursor_row, state.current_file)
    state.scroll_mode = true

    local result = M.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user)
    state.file_sections = result.file_sections
    state.scroll_line_data = result.line_data
    state.scroll_row_disc = result.row_discussions
    state.scroll_row_ai = result.row_ai
    local row = M.find_row_for_anchor(state.scroll_line_data, anchor)
    vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
  end

  M.render_sidebar(layout.sidebar_buf, state)
  vim.notify(state.scroll_mode and "All-files view" or "Per-file view", vim.log.levels.INFO)
end

-- ─── Keymaps ─────────────────────────────────────────────────────────────────

function M.setup_keymaps(layout, state)
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
  local function rerender_view()
    local view = vim.fn.winsaveview()

    if state.scroll_mode then
      local result = M.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user, state.editing_note)
      state.file_sections = result.file_sections
      state.scroll_line_data = result.line_data
      state.scroll_row_disc = result.row_discussions
      state.scroll_row_ai = result.row_ai
    else
      local file = state.files and state.files[state.current_file]
      if file then
        local ld, rd, ra = M.render_file_diff(layout.main_buf, file, state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user, state.editing_note)
        state.line_data_cache[state.current_file] = ld
        state.row_disc_cache[state.current_file] = rd
        state.row_ai_cache[state.current_file] = ra
      end
    end

    -- Clamp cursor to buffer bounds then restore scroll position
    local max_line = vim.api.nvim_buf_line_count(layout.main_buf)
    view.lnum = math.min(view.lnum, max_line)
    view.topline = math.min(view.topline, max_line)
    vim.fn.winrestview(view)
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
      M.render_summary(layout.main_buf, state)
      M.render_sidebar(layout.sidebar_buf, state)
      return
    end
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
      local result = M.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user)
      state.file_sections = result.file_sections
      state.scroll_line_data = result.line_data
      state.scroll_row_disc = result.row_discussions
      state.scroll_row_ai = result.row_ai
    else
      local file = state.files and state.files[state.current_file]
      if not file then return end
      local ld, rd, ra = M.render_file_diff(layout.main_buf, file, state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user)
      state.line_data_cache[state.current_file] = ld
      state.row_disc_cache[state.current_file] = rd
      state.row_ai_cache[state.current_file] = ra
    end
    M.render_sidebar(layout.sidebar_buf, state)
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
            M.render_sidebar(layout.sidebar_buf, state)
            return
          end
        end
      else
        nav_file(layout, state, 1)
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
            M.render_sidebar(layout.sidebar_buf, state)
            return
          end
        end
      else
        nav_file(layout, state, -1)
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
          comment.create_inline_draft(state.review, file.new_path, data.item.new_line,
            add_local_draft(file.new_path, data.item.new_line), popup_opts)
        else
          comment.create_inline(state.review, file.old_path, file.new_path, data.item.old_line, data.item.new_line, {
            add = add_optimistic_comment(file.old_path, file.new_path, data.item.old_line, data.item.new_line),
            remove = remove_optimistic,
            mark_failed = mark_optimistic_failed,
            refresh = refresh_discussions,
          }, popup_opts)
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
          comment.create_inline_draft(state.review, file.new_path, data.item.new_line,
            add_local_draft(file.new_path, data.item.new_line),
            { anchor_line = row, win_id = layout.main_win, action_type = "comment", context_text = line_text })
        else
          M.create_comment_at_cursor(layout, state, {
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
          comment.create_inline_range_draft(
            state.review,
            file.new_path,
            start_data.item.new_line,
            end_data.item.new_line,
            add_local_draft(file.new_path, end_data.item.new_line, start_data.item.new_line),
            popup_opts
          )
        else
          comment.create_inline_range(
            state.review,
            file.old_path,
            file.new_path,
            { old_line = start_data.item.old_line, new_line = start_data.item.new_line },
            { old_line = end_data.item.old_line, new_line = end_data.item.new_line },
            {
              add = add_optimistic_comment(file.old_path, file.new_path, end_data.item.old_line, end_data.item.new_line, start_data.item.new_line),
              remove = remove_optimistic,
              mark_failed = mark_optimistic_failed,
              refresh = refresh_discussions,
            },
            popup_opts
          )
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
          comment.create_inline_range_draft(
            state.review,
            file.new_path,
            start_data.item.new_line,
            end_data.item.new_line,
            add_local_draft(file.new_path, end_data.item.new_line, start_data.item.new_line),
            { anchor_line = e, anchor_start = s, win_id = layout.main_win, action_type = "comment", context_text = line_text }
          )
        else
          M.create_comment_range(layout, state, {
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
      adjust_context(layout, state, 1)
    end,

    decrease_context = function()
      if state.view_mode ~= "diff" then return end
      adjust_context(layout, state, -1)
    end,

    toggle_full_file = function()
      if state.view_mode ~= "diff" then return end
      local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      if state.scroll_mode then
        local file_idx = current_file_from_cursor(layout, state)
        local anchor = M.find_anchor(state.scroll_line_data, cursor_row)
        if state.file_contexts[file_idx] then
          state.file_contexts[file_idx] = nil
        else
          state.file_contexts[file_idx] = 99999
        end
        local result = M.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user)
        state.file_sections = result.file_sections
        state.scroll_line_data = result.line_data
        state.scroll_row_disc = result.row_discussions
        state.scroll_row_ai = result.row_ai
        local row = M.find_row_for_anchor(state.scroll_line_data, anchor)
        vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
      else
        local per_file_ld = state.line_data_cache[state.current_file]
        local anchor = M.find_anchor(per_file_ld or {}, cursor_row, state.current_file)
        if state.context == 99999 then
          state.context = config.get().diff.context
        else
          state.context = 99999
        end
        local file = state.files and state.files[state.current_file]
        if not file then return end
        local ld, rd, ra = M.render_file_diff(layout.main_buf, file, state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user)
        state.line_data_cache[state.current_file] = ld
        state.row_disc_cache[state.current_file] = rd
        state.row_ai_cache[state.current_file] = ra
        local row = M.find_row_for_anchor(ld, anchor, state.current_file)
        vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
      end
    end,

    toggle_scroll_mode = function()
      if state.view_mode ~= "diff" then return end
      toggle_scroll_mode(layout, state)
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
      M.render_sidebar(layout.sidebar_buf, state)
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
      rerender_view()

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
            rerender_view()
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
      if state.view_mode ~= "diff" then return end
      local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local row_ai = state.scroll_mode and state.scroll_row_ai or (state.row_ai_cache[state.current_file] or {})
      local row_disc_map = state.scroll_mode and state.scroll_row_disc or (state.row_disc_cache[state.current_file] or {})
      local ai_at_row = row_ai[cursor_row] or {}
      local discs_at_row = row_disc_map[cursor_row] or {}
      local items = M.build_row_items(ai_at_row, discs_at_row)

      -- Try cycling within current row first
      if #items > 0 then
        local current = state.row_selection[cursor_row]
        local next_sel = M.cycle_row_selection(items, current, 1)
        if next_sel then
          state.row_selection = { [cursor_row] = next_sel }
          rerender_view()
          return
        end
      end

      -- Past edge (or empty row): jump to next annotated row
      local all_rows = M.get_annotated_rows(row_disc_map, row_ai)
      for _, r in ipairs(all_rows) do
        if r > cursor_row then
          vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
          M.ensure_virt_lines_visible(layout.main_win, layout.main_buf, r)
          local next_ai = row_ai[r] or {}
          local next_disc = row_disc_map[r] or {}
          local next_items = M.build_row_items(next_ai, next_disc)
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
          M.ensure_virt_lines_visible(layout.main_win, layout.main_buf, r)
          local next_ai = row_ai[r] or {}
          local next_disc = row_disc_map[r] or {}
          local next_items = M.build_row_items(next_ai, next_disc)
          state.row_selection = { [r] = next_items[1] or nil }
          rerender_view()
        end
      else
        -- Per-file mode: try next files, wrapping around
        local files = state.files or {}
        local total = #files
        for offset = 1, total do
          local idx = ((state.current_file - 1 + offset) % total) + 1
          if M.file_has_annotations(state, idx) then
            switch_to_file(layout, state, idx)
            local ra = state.row_ai_cache[idx] or {}
            local rd = state.row_disc_cache[idx] or {}
            local rows = M.get_annotated_rows(rd, ra)
            if #rows > 0 then
              vim.api.nvim_win_set_cursor(layout.main_win, { rows[1], 0 })
              M.ensure_virt_lines_visible(layout.main_win, layout.main_buf, rows[1])
              local next_ai = ra[rows[1]] or {}
              local next_disc = rd[rows[1]] or {}
              local next_items = M.build_row_items(next_ai, next_disc)
              state.row_selection = { [rows[1]] = next_items[1] or nil }
              rerender_view()
            end
            return
          end
        end
      end
    end,

    select_prev_note = function()
      if state.view_mode ~= "diff" then return end
      local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local row_ai = state.scroll_mode and state.scroll_row_ai or (state.row_ai_cache[state.current_file] or {})
      local row_disc_map = state.scroll_mode and state.scroll_row_disc or (state.row_disc_cache[state.current_file] or {})
      local ai_at_row = row_ai[cursor_row] or {}
      local discs_at_row = row_disc_map[cursor_row] or {}
      local items = M.build_row_items(ai_at_row, discs_at_row)

      -- Try cycling within current row first
      if #items > 0 then
        local current = state.row_selection[cursor_row]
        local next_sel = M.cycle_row_selection(items, current, -1)
        if next_sel then
          state.row_selection = { [cursor_row] = next_sel }
          rerender_view()
          return
        end
      end

      -- Past edge: jump to prev annotated row
      local all_rows = M.get_annotated_rows(row_disc_map, row_ai)
      for i = #all_rows, 1, -1 do
        if all_rows[i] < cursor_row then
          local r = all_rows[i]
          vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
          M.ensure_virt_lines_visible(layout.main_win, layout.main_buf, r)
          local prev_ai = row_ai[r] or {}
          local prev_disc = row_disc_map[r] or {}
          local prev_items = M.build_row_items(prev_ai, prev_disc)
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
          M.ensure_virt_lines_visible(layout.main_win, layout.main_buf, r)
          local prev_ai = row_ai[r] or {}
          local prev_disc = row_disc_map[r] or {}
          local prev_items = M.build_row_items(prev_ai, prev_disc)
          state.row_selection = { [r] = prev_items[#prev_items] or nil }
          rerender_view()
        end
      else
        local files = state.files or {}
        local total = #files
        for offset = 1, total do
          local idx = ((state.current_file - 1 - offset) % total) + 1
          if M.file_has_annotations(state, idx) then
            switch_to_file(layout, state, idx)
            local ra = state.row_ai_cache[idx] or {}
            local rd = state.row_disc_cache[idx] or {}
            local rows = M.get_annotated_rows(rd, ra)
            if #rows > 0 then
              local r = rows[#rows]
              vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
              M.ensure_virt_lines_visible(layout.main_win, layout.main_buf, r)
              local prev_ai = ra[r] or {}
              local prev_disc = rd[r] or {}
              local prev_items = M.build_row_items(prev_ai, prev_disc)
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
      nav_file(layout, state, 1)
    end,
    prev_file = function()
      if state.view_mode ~= "diff" then return end
      nav_file(layout, state, -1)
    end,
    toggle_scroll_mode = function()
      if state.view_mode ~= "diff" then return end
      toggle_scroll_mode(layout, state)
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
      adjust_context(layout, state, 10)
    end
  end)

  -- Sidebar: <CR> to select file, toggle directory, or open summary
  map(sidebar_buf, "n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(layout.sidebar_win)
    local row = cursor[1]
    local entry = state.sidebar_row_map and state.sidebar_row_map[row]
    if not entry then return end

    if entry.type == "summary" then
      state.view_mode = "summary"
      M.render_sidebar(layout.sidebar_buf, state)
      M.render_summary(layout.main_buf, state)
      vim.api.nvim_win_set_cursor(layout.main_win, { 1, 0 })
      vim.api.nvim_set_current_win(layout.main_win)

    elseif entry.type == "dir" then
      if not state.collapsed_dirs then state.collapsed_dirs = {} end
      if state.collapsed_dirs[entry.path] then
        state.collapsed_dirs[entry.path] = nil
      else
        state.collapsed_dirs[entry.path] = true
      end
      M.render_sidebar(layout.sidebar_buf, state)
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
        M.load_diffs_into_state(state, files or {})
        M.render_sidebar(layout.sidebar_buf, state)
      end

      state.view_mode = "diff"
      state.current_file = entry.idx
      state.row_selection = {}
      vim.wo[layout.main_win].wrap = false
      vim.wo[layout.main_win].linebreak = false

      if state.scroll_mode then
        -- Always re-render all files (buffer may have summary content)
        local result = M.render_all_files(layout.main_buf, state.files, state.review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user)
        state.file_sections = result.file_sections
        state.scroll_line_data = result.line_data
        state.scroll_row_disc = result.row_discussions
        state.scroll_row_ai = result.row_ai
        M.render_sidebar(layout.sidebar_buf, state)
        for _, sec in ipairs(state.file_sections) do
          if sec.file_idx == entry.idx then
            vim.api.nvim_win_set_cursor(layout.main_win, { sec.start_line, 0 })
            break
          end
        end
      else
        M.render_sidebar(layout.sidebar_buf, state)
        local line_data, row_disc, row_ai = M.render_file_diff(
          layout.main_buf, state.files[entry.idx], state.review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user)
        state.line_data_cache[entry.idx] = line_data
        state.row_disc_cache[entry.idx] = row_disc
        state.row_ai_cache[entry.idx] = row_ai
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
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = main_buf,
    callback = function()
      if state.view_mode ~= "diff" then return end

      local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local row_ai = state.scroll_mode and state.scroll_row_ai or (state.row_ai_cache[state.current_file] or {})
      local ai_at_row = row_ai[cursor_row] or {}
      local row_disc_map = state.scroll_mode and state.scroll_row_disc or (state.row_disc_cache[state.current_file] or {})
      local discs_at_row = row_disc_map[cursor_row] or {}

      local items = M.build_row_items(ai_at_row, discs_at_row)
      if #items > 0 then
        local prev_sel = state.row_selection[cursor_row]
        if not prev_sel then
          -- Auto-select first item on entering a row with items
          state.row_selection = { [cursor_row] = items[1] }
          rerender_view()
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
            state.row_selection = { [cursor_row] = items[1] }
            rerender_view()
          elseif next(state.row_selection, next(state.row_selection)) or not state.row_selection[cursor_row] then
            -- Clear selections on other rows
            state.row_selection = { [cursor_row] = state.row_selection[cursor_row] }
            rerender_view()
          end
        end
      else
        local had = next(state.row_selection) ~= nil
        state.row_selection = {}
        if had then rerender_view() end
      end

      -- Sync sidebar file highlight in scroll mode
      if state.scroll_mode and #state.file_sections > 0 then
        local file_idx = current_file_from_cursor(layout, state)
        if file_idx ~= state.current_file then
          state.current_file = file_idx
          M.render_sidebar(layout.sidebar_buf, state)
        end
      end
    end,
  })
end

-- ─── Lazy diff loading ──────────────────────────────────────────────────────

function M.load_diffs_into_state(state, files)
  if state.files then return end
  local config = require("codereview.config")
  local cfg = config.get()
  state.files = files
  state.scroll_mode = #files <= cfg.diff.scroll_threshold
  state.line_data_cache = state.line_data_cache or {}
  state.row_disc_cache = state.row_disc_cache or {}
  state.file_sections = state.file_sections or {}
  state.scroll_line_data = state.scroll_line_data or {}
  state.scroll_row_disc = state.scroll_row_disc or {}
  state.file_contexts = state.file_contexts or {}
  state.row_ai_cache = state.row_ai_cache or {}
  state.scroll_row_ai = state.scroll_row_ai or {}
  state.local_drafts = state.local_drafts or {}
  state.row_selection = state.row_selection or {}
  state.current_file = 1
end

-- ─── Main entry point ─────────────────────────────────────────────────────────

function M.open(review, discussions)
  local providers = require("codereview.providers")
  local client_mod = require("codereview.api.client")
  local split = require("codereview.ui.split")

  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify(err or "Could not detect platform", vim.log.levels.ERROR)
    return
  end

  local files, fetch_err = provider.get_diffs(client_mod, ctx, review)
  if not files then
    vim.notify(fetch_err or "Failed to fetch diffs", vim.log.levels.ERROR)
    return
  end

  local layout = split.create()

  local cfg = config.get()
  local state = {
    view_mode = "diff",
    review = review,
    provider = provider,
    ctx = ctx,
    files = files,
    current_file = 1,
    layout = layout,
    discussions = discussions or {},
    line_data_cache = {},
    row_disc_cache = {},
    sidebar_row_map = {},
    collapsed_dirs = {},
    context = cfg.diff.context,
    scroll_mode = #files <= cfg.diff.scroll_threshold,
    file_sections = {},
    scroll_line_data = {},
    scroll_row_disc = {},
    file_contexts = {},
    ai_suggestions = nil,
    row_ai_cache = {},
    scroll_row_ai = {},
    local_drafts = {},
    row_selection = {},
    current_user = nil,
  }

  M.render_sidebar(layout.sidebar_buf, state)

  -- Fetch current user for note authorship checks (edit/delete guards)
  local user = provider.get_current_user(client_mod, ctx)
  if user then state.current_user = user end

  if #files > 0 then
    if state.scroll_mode then
      local render_result = M.render_all_files(layout.main_buf, files, review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user)
      state.file_sections = render_result.file_sections
      state.scroll_line_data = render_result.line_data
      state.scroll_row_disc = render_result.row_discussions
      state.scroll_row_ai = render_result.row_ai
    else
      local line_data, row_disc, row_ai = M.render_file_diff(layout.main_buf, files[1], review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user)
      state.line_data_cache[1] = line_data
      state.row_disc_cache[1] = row_disc
      state.row_ai_cache[1] = row_ai
    end
  else
    vim.bo[layout.main_buf].modifiable = true
    vim.api.nvim_buf_set_lines(layout.main_buf, 0, -1, false, { "No diffs found." })
    vim.bo[layout.main_buf].modifiable = false
  end

  M.setup_keymaps(layout, state)
  vim.api.nvim_set_current_win(layout.main_win)

  -- Check for server-side draft comments
  local drafts_mod = require("codereview.review.drafts")
  drafts_mod.check_and_prompt(provider, client_mod, ctx, review, function(server_drafts)
    if server_drafts then
      local session = require("codereview.review.session")
      session.start()
      for _, d in ipairs(server_drafts) do
        table.insert(state.local_drafts, d)
        table.insert(state.discussions, d)
      end
      -- Re-render to show draft markers
      M.render_sidebar(layout.sidebar_buf, state)
      if state.scroll_mode then
        local render_result = M.render_all_files(layout.main_buf, state.files, review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user)
        state.file_sections = render_result.file_sections
        state.scroll_line_data = render_result.line_data
        state.scroll_row_disc = render_result.row_discussions
        state.scroll_row_ai = render_result.row_ai
      else
        M.render_file_diff(layout.main_buf, state.files[state.current_file], review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user)
      end
    end
  end)
end

return M
