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

-- ─── Text helpers ───────────────────────────────────────────────────────────

local function wrap_text(text, width)
  local result = {}
  for _, paragraph in ipairs(vim.split(text or "", "\n")) do
    if paragraph == "" then
      table.insert(result, "")
    elseif #paragraph <= width then
      table.insert(result, paragraph)
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        if line ~= "" and #line + #word + 1 > width then
          table.insert(result, line)
          line = word
        else
          line = line == "" and word or (line .. " " .. word)
        end
      end
      if line ~= "" then table.insert(result, line) end
    end
  end
  return result
end

local function format_time_short(iso_str)
  if not iso_str then return "" end
  local mo, d, h, mi = iso_str:match("%d+-(%d+)-(%d+)T(%d+):(%d+)")
  if not mo then return "" end
  return string.format("%s/%s %s:%s", mo, d, h, mi)
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

  -- Track which rows have discussions (for keymap lookups)
  local row_discussions = {}

  for _, discussion in ipairs(discussions or {}) do
    if discussion_matches_file(discussion, file_diff) then
      local target_line = discussion_line(discussion)
      if target_line then
        for row, data in ipairs(line_data) do
          local item = data.item
          if item and (item.new_line == target_line or item.old_line == target_line) then
            -- Place gutter sign
            local sign_name = is_resolved(discussion) and "GlabReviewCommentSign"
              or "GlabReviewUnresolvedSign"
            pcall(vim.fn.sign_place, 0, "GlabReview", sign_name, buf, { lnum = row })

            -- Render full comment thread inline
            local notes = discussion.notes
            if notes and #notes > 0 then
              local first = notes[1]
              local resolved = is_resolved(discussion)
              local bdr = "GlabReviewCommentBorder"
              local aut = "GlabReviewCommentAuthor"
              local body_hl = resolved and "GlabReviewComment" or "GlabReviewCommentUnresolved"
              local status_hl = resolved and "GlabReviewCommentResolved" or "GlabReviewCommentUnresolved"
              local status_str = resolved and " Resolved " or " Unresolved "
              local time_str = format_time_short(first.created_at)
              local header_meta = time_str ~= "" and (" · " .. time_str) or ""
              local header_text = "@" .. first.author.username
              local fill = math.max(0, 62 - #header_text - #header_meta - #status_str)

              local virt_lines = {}

              -- ┌ @author · 02/15 14:30 · Unresolved ─────────
              table.insert(virt_lines, {
                { "  ┌ ", bdr },
                { header_text, aut },
                { header_meta, bdr },
                { status_str, status_hl },
                { string.rep("─", fill), bdr },
              })

              -- Comment body (wrapped, full)
              for _, bl in ipairs(wrap_text(first.body, 64)) do
                table.insert(virt_lines, {
                  { "  │ ", bdr },
                  { bl, body_hl },
                })
              end

              -- Replies
              for i = 2, #notes do
                local reply = notes[i]
                if not reply.system then
                  local rt = format_time_short(reply.created_at)
                  local rmeta = rt ~= "" and (" · " .. rt) or ""
                  table.insert(virt_lines, { { "  │", bdr } })
                  table.insert(virt_lines, {
                    { "  │  ↪ ", bdr },
                    { "@" .. reply.author.username, aut },
                    { rmeta, bdr },
                  })
                  for _, rl in ipairs(wrap_text(reply.body, 58)) do
                    table.insert(virt_lines, {
                      { "  │    ", bdr },
                      { rl, body_hl },
                    })
                  end
                end
              end

              -- └ Enter: reply/resolve ──────────────────────
              table.insert(virt_lines, {
                { "  └ ", bdr },
                { "r:reply  gt:un/resolve", body_hl },
                { " " .. string.rep("─", 44), bdr },
              })

              pcall(vim.api.nvim_buf_set_extmark, buf, DIFF_NS, row - 1, 0, {
                virt_lines = virt_lines,
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

-- ─── Diff rendering ───────────────────────────────────────────────────────────

function M.render_file_diff(buf, file_diff, mr, discussions, context)
  local parser = require("glab_review.mr.diff_parser")
  if not context then
    context = require("glab_review.config").get().diff.context
  end

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
  local display = parser.build_display(hunks, 99999)

  -- Get file line count for BOF/EOF detection
  local file_line_count
  local file_path = file_diff.new_path or file_diff.old_path
  if file_path and mr.diff_refs and mr.diff_refs.head_sha then
    local wc = vim.fn.system({
      "git", "show", mr.diff_refs.head_sha .. ":" .. file_path,
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
    local prefix = M.format_line_number(item.old_line, item.new_line)
    table.insert(lines, prefix .. (item.text or ""))
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
    elseif data.type == "load_more" then
      apply_line_hl(buf, row, "GlabReviewHidden")
      prev_delete_row = nil
      prev_delete_text = nil
    else
      prev_delete_row = nil
      prev_delete_text = nil
    end
  end

  local row_discussions = {}
  if discussions then
    row_discussions = M.place_comment_signs(buf, line_data, discussions, file_diff) or {}
  end

  return line_data, row_discussions
end

-- ─── All-files scroll view ────────────────────────────────────────────────────

function M.render_all_files(buf, files, mr, discussions, context, file_contexts)
  local parser = require("glab_review.mr.diff_parser")
  local config = require("glab_review.config")
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
    if mr.diff_refs and mr.diff_refs.base_sha and mr.diff_refs.head_sha then
      local fpath = file_diff.new_path or file_diff.old_path
      if fpath then
        local result = vim.fn.system({
          "git", "diff", "-U" .. file_ctx,
          mr.diff_refs.base_sha, mr.diff_refs.head_sha, "--", fpath,
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
        local prefix = M.format_line_number(item.old_line, item.new_line)
        table.insert(all_lines, prefix .. (item.text or ""))
        table.insert(all_line_data, { type = item.type, item = item, file_idx = file_idx })
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
    if data.type == "file_header" then
      apply_line_hl(buf, row, "GlabReviewFileHeader")
      prev_delete_row = nil
      prev_delete_text = nil
    elseif data.type == "add" then
      apply_line_hl(buf, row, "GlabReviewDiffAdd")
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
      if discussion_matches_file(disc, section.file) then
        local target_line = discussion_line(disc)
        if target_line then
          for i = section.start_line, section.end_line do
            local data = all_line_data[i]
            if data.item and (data.item.new_line == target_line or data.item.old_line == target_line) then
              local sign_name = is_resolved(disc) and "GlabReviewCommentSign"
                or "GlabReviewUnresolvedSign"
              pcall(vim.fn.sign_place, 0, "GlabReview", sign_name, buf, { lnum = i })

              local notes = disc.notes
              if notes and #notes > 0 then
                local first = notes[1]
                local resolved = is_resolved(disc)
                local bdr = "GlabReviewCommentBorder"
                local aut = "GlabReviewCommentAuthor"
                local body_hl = resolved and "GlabReviewComment" or "GlabReviewCommentUnresolved"
                local status_hl = resolved and "GlabReviewCommentResolved" or "GlabReviewCommentUnresolved"
                local status_str = resolved and " Resolved " or " Unresolved "
                local time_str = format_time_short(first.created_at)
                local header_meta = time_str ~= "" and (" · " .. time_str) or ""
                local header_text = "@" .. first.author.username
                local fill = math.max(0, 62 - #header_text - #header_meta - #status_str)

                local virt_lines = {}
                table.insert(virt_lines, {
                  { "  ┌ ", bdr }, { header_text, aut },
                  { header_meta, bdr }, { status_str, status_hl },
                  { string.rep("─", fill), bdr },
                })
                for _, bl in ipairs(wrap_text(first.body, 64)) do
                  table.insert(virt_lines, { { "  │ ", bdr }, { bl, body_hl } })
                end
                for ni = 2, #notes do
                  local reply = notes[ni]
                  if not reply.system then
                    local rt = format_time_short(reply.created_at)
                    local rmeta = rt ~= "" and (" · " .. rt) or ""
                    table.insert(virt_lines, { { "  │", bdr } })
                    table.insert(virt_lines, {
                      { "  │  ↪ ", bdr }, { "@" .. reply.author.username, aut }, { rmeta, bdr },
                    })
                    for _, rl in ipairs(wrap_text(reply.body, 58)) do
                      table.insert(virt_lines, { { "  │    ", bdr }, { rl, body_hl } })
                    end
                  end
                end
                table.insert(virt_lines, {
                  { "  └ ", bdr }, { "r:reply  gt:un/resolve", body_hl },
                  { " " .. string.rep("─", 44), bdr },
                })
                pcall(vim.api.nvim_buf_set_extmark, buf, DIFF_NS, i - 1, 0, {
                  virt_lines = virt_lines, virt_lines_above = false,
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

  return {
    file_sections = file_sections,
    line_data = all_line_data,
    row_discussions = all_row_discussions,
  }
end

-- ─── Sidebar rendering ────────────────────────────────────────────────────────

local function count_file_comments(file, discussions)
  local n = 0
  for _, disc in ipairs(discussions or {}) do
    if discussion_matches_file(disc, file) then n = n + 1 end
  end
  return n
end

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
        local indicator = (entry.idx == state.current_file) and "▸" or " "
        local ccount = count_file_comments(files[entry.idx], state.discussions)
        local cstr = ccount > 0 and (" [" .. ccount .. "]") or ""
        local name = entry.name
        local max_name = 22 - #cstr
        if #name > max_name then name = ".." .. name:sub(-(max_name - 2)) end
        table.insert(lines, string.format("  %s %s%s", indicator, name, cstr))
        state.sidebar_row_map[#lines] = { type = "file", idx = entry.idx }
      end
    end
  end

  -- Root-level files
  for _, entry in ipairs(root_files) do
    local indicator = (entry.idx == state.current_file) and "▸" or " "
    local ccount = count_file_comments(files[entry.idx], state.discussions)
    local cstr = ccount > 0 and (" [" .. ccount .. "]") or ""
    local name = entry.name
    local max_name = 24 - #cstr
    if #name > max_name then name = ".." .. name:sub(-(max_name - 2)) end
    table.insert(lines, string.format("%s %s%s", indicator, name, cstr))
    state.sidebar_row_map[#lines] = { type = "file", idx = entry.idx }
  end

  table.insert(lines, "")
  table.insert(lines, string.rep("─", 30))
  table.insert(lines, "]f/[f  ]c/[c  cc:comment")
  table.insert(lines, "r:reply  gt:un/resolve")
  table.insert(lines, "s:summary  R:refresh  q:quit")
  table.insert(lines, "+/- context  C-f:full file")
  table.insert(lines, "<C-a>:toggle view")

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Highlight current file + directory headers
  vim.api.nvim_buf_clear_namespace(buf, DIFF_NS, 0, -1)
  for row, entry in pairs(state.sidebar_row_map) do
    if entry.type == "file" and entry.idx == state.current_file then
      pcall(apply_line_hl, buf, row - 1, "GlabReviewFileChanged")
    elseif entry.type == "dir" then
      pcall(apply_line_hl, buf, row - 1, "GlabReviewHidden")
    end
  end
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
  local line_data, row_disc = M.render_file_diff(layout.main_buf, files[next_idx], state.mr, state.discussions, state.context)
  state.line_data_cache[next_idx] = line_data
  state.row_disc_cache[next_idx] = row_disc
  vim.api.nvim_win_set_cursor(layout.main_win, { 1, 0 })
end

local function get_comment_rows(state, file_idx)
  local rd = state.row_disc_cache[file_idx]
  if not rd then return {} end
  local rows = {}
  for r, _ in pairs(rd) do table.insert(rows, r) end
  table.sort(rows)
  return rows
end

local function file_has_comments(state, file_idx)
  local files = state.files or {}
  for _, disc in ipairs(state.discussions or {}) do
    if discussion_matches_file(disc, files[file_idx]) then return true end
  end
  return false
end

local function switch_to_file(layout, state, idx)
  state.current_file = idx
  M.render_sidebar(layout.sidebar_buf, state)
  local ld, rd = M.render_file_diff(
    layout.main_buf, state.files[idx], state.mr, state.discussions, state.context)
  state.line_data_cache[idx] = ld
  state.row_disc_cache[idx] = rd
end

local function nav_comment(layout, state, delta)
  local files = state.files or {}
  local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
  local current_row = cursor[1]
  local comment_rows = get_comment_rows(state, state.current_file)

  if delta > 0 then
    -- Next comment in current file
    for _, r in ipairs(comment_rows) do
      if r > current_row then
        vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
        return
      end
    end
    -- Move to next file with comments
    for i = state.current_file + 1, #files do
      if file_has_comments(state, i) then
        switch_to_file(layout, state, i)
        local rows = get_comment_rows(state, i)
        if #rows > 0 then
          vim.api.nvim_win_set_cursor(layout.main_win, { rows[1], 0 })
        end
        return
      end
    end
  else
    -- Prev comment in current file
    for i = #comment_rows, 1, -1 do
      if comment_rows[i] < current_row then
        vim.api.nvim_win_set_cursor(layout.main_win, { comment_rows[i], 0 })
        return
      end
    end
    -- Move to prev file with comments
    for i = state.current_file - 1, 1, -1 do
      if file_has_comments(state, i) then
        switch_to_file(layout, state, i)
        local rows = get_comment_rows(state, i)
        if #rows > 0 then
          vim.api.nvim_win_set_cursor(layout.main_win, { rows[#rows], 0 })
        end
        return
      end
    end
  end
end

-- ─── Context adjustment ─────────────────────────────────────────────────────

local function adjust_context(layout, state, delta)
  local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
  state.context = math.max(1, state.context + delta)
  if state.scroll_mode then
    local result = M.render_all_files(layout.main_buf, state.files, state.mr, state.discussions, state.context, state.file_contexts)
    state.file_sections = result.file_sections
    state.scroll_line_data = result.line_data
    state.scroll_row_disc = result.row_discussions
  else
    local file = state.files and state.files[state.current_file]
    if not file then return end
    local line_data, row_disc = M.render_file_diff(
      layout.main_buf, file, state.mr, state.discussions, state.context)
    state.line_data_cache[state.current_file] = line_data
    state.row_disc_cache[state.current_file] = row_disc
  end
  vim.api.nvim_win_set_cursor(layout.main_win, { math.min(cursor[1], vim.api.nvim_buf_line_count(layout.main_buf)), 0 })
  vim.notify("Context: " .. state.context .. " lines", vim.log.levels.INFO)
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
  state.scroll_mode = not state.scroll_mode
  if state.scroll_mode then
    local result = M.render_all_files(layout.main_buf, state.files, state.mr, state.discussions, state.context, state.file_contexts)
    state.file_sections = result.file_sections
    state.scroll_line_data = result.line_data
    state.scroll_row_disc = result.row_discussions
    -- Scroll to current file's section
    for _, sec in ipairs(state.file_sections) do
      if sec.file_idx == state.current_file then
        vim.api.nvim_win_set_cursor(layout.main_win, { sec.start_line, 0 })
        break
      end
    end
  else
    -- Switch back to per-file: render current file
    local file = state.files[state.current_file]
    if file then
      local ld, rd = M.render_file_diff(layout.main_buf, file, state.mr, state.discussions, state.context)
      state.line_data_cache[state.current_file] = ld
      state.row_disc_cache[state.current_file] = rd
    end
  end
  M.render_sidebar(layout.sidebar_buf, state)
  vim.notify(state.scroll_mode and "All-files view" or "Per-file view", vim.log.levels.INFO)
end

-- ─── Keymaps ─────────────────────────────────────────────────────────────────

function M.setup_keymaps(layout, state)
  local main_buf = layout.main_buf
  local sidebar_buf = layout.sidebar_buf
  local opts = { noremap = true, silent = true, nowait = true }

  local function map(buf, mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, vim.tbl_extend("force", opts, { buffer = buf }))
  end

  -- Scroll mode toggle
  map(main_buf, "n", "<C-a>", function() toggle_scroll_mode(layout, state) end)
  map(sidebar_buf, "n", "<C-a>", function() toggle_scroll_mode(layout, state) end)

  -- File navigation
  map(main_buf, "n", "]f", function()
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
  end)
  map(main_buf, "n", "[f", function()
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
  end)
  map(sidebar_buf, "n", "]f", function() nav_file(layout, state, 1) end)
  map(sidebar_buf, "n", "[f", function() nav_file(layout, state, -1) end)

  -- Comment navigation
  map(main_buf, "n", "]c", function()
    if state.scroll_mode then
      local cursor = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local rows = {}
      for r in pairs(state.scroll_row_disc or {}) do table.insert(rows, r) end
      table.sort(rows)
      for _, r in ipairs(rows) do
        if r > cursor then
          vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
          return
        end
      end
    else
      nav_comment(layout, state, 1)
    end
  end)
  map(main_buf, "n", "[c", function()
    if state.scroll_mode then
      local cursor = vim.api.nvim_win_get_cursor(layout.main_win)[1]
      local rows = {}
      for r in pairs(state.scroll_row_disc or {}) do table.insert(rows, r) end
      table.sort(rows)
      for i = #rows, 1, -1 do
        if rows[i] < cursor then
          vim.api.nvim_win_set_cursor(layout.main_win, { rows[i], 0 })
          return
        end
      end
    else
      nav_comment(layout, state, -1)
    end
  end)

  -- Comment creation
  map(main_buf, "n", "cc", function()
    if state.scroll_mode then
      local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
      local row = cursor[1]
      local data = state.scroll_line_data[row]
      if not data or not data.item then
        vim.notify("No diff line at cursor", vim.log.levels.WARN)
        return
      end
      local file = state.files[data.file_idx]
      local comment = require("glab_review.mr.comment")
      comment.create_inline(state.mr, file.old_path, file.new_path, data.item.old_line, data.item.new_line)
    else
      M.create_comment_at_cursor(layout, state)
    end
  end)
  map(main_buf, "v", "cc", function()
    if state.scroll_mode then
      local start_row = vim.fn.line("'<")
      local end_row = vim.fn.line("'>")
      local start_data = state.scroll_line_data[start_row]
      local end_data = state.scroll_line_data[end_row]
      if not start_data or not start_data.item or not end_data or not end_data.item then
        vim.notify("Invalid selection range", vim.log.levels.WARN)
        return
      end
      local file = state.files[start_data.file_idx]
      local comment = require("glab_review.mr.comment")
      comment.create_inline_range(
        state.mr,
        file.old_path,
        file.new_path,
        { old_line = start_data.item.old_line, new_line = start_data.item.new_line },
        { old_line = end_data.item.old_line, new_line = end_data.item.new_line }
      )
    else
      M.create_comment_range(layout, state)
    end
  end)

  -- Load more context
  map(main_buf, "n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
    local row = cursor[1]
    local line_data = state.line_data_cache[state.current_file]
    if not line_data or not line_data[row] then return end
    if line_data[row].type == "load_more" then
      adjust_context(layout, state, 10)
    end
  end)

  -- Reply to comment thread on current line
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

  map(main_buf, "n", "r", function()
    local disc = get_cursor_disc()
    if disc then
      local comment = require("glab_review.mr.comment")
      comment.reply(disc, state.mr)
    end
  end)

  map(main_buf, "n", "gt", function()
    local disc = get_cursor_disc()
    if disc then
      local comment = require("glab_review.mr.comment")
      comment.resolve_toggle(disc, state.mr, function()
        -- Re-render to update resolved status
        if state.scroll_mode then
          local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
          local result = M.render_all_files(layout.main_buf, state.files, state.mr, state.discussions, state.context, state.file_contexts)
          state.file_sections = result.file_sections
          state.scroll_line_data = result.line_data
          state.scroll_row_disc = result.row_discussions
          vim.api.nvim_win_set_cursor(layout.main_win, { math.min(cursor[1], vim.api.nvim_buf_line_count(layout.main_buf)), 0 })
        else
          local file = state.files and state.files[state.current_file]
          if file then
            local ld, rd = M.render_file_diff(
              layout.main_buf, file, state.mr, state.discussions, state.context)
            state.line_data_cache[state.current_file] = ld
            state.row_disc_cache[state.current_file] = rd
          end
        end
        vim.notify("Resolve status toggled", vim.log.levels.INFO)
      end)
    end
  end)

  -- Context adjustment
  map(main_buf, "n", "+", function() adjust_context(layout, state, 5) end)
  map(main_buf, "n", "-", function() adjust_context(layout, state, -5) end)

  -- Toggle full file (current file only in scroll mode)
  map(main_buf, "n", "<C-f>", function()
    local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
    if state.scroll_mode then
      local file_idx = current_file_from_cursor(layout, state)
      if state.file_contexts[file_idx] then
        state.file_contexts[file_idx] = nil
      else
        state.file_contexts[file_idx] = 99999
      end
      local result = M.render_all_files(layout.main_buf, state.files, state.mr, state.discussions, state.context, state.file_contexts)
      state.file_sections = result.file_sections
      state.scroll_line_data = result.line_data
      state.scroll_row_disc = result.row_discussions
    else
      if state.context == 99999 then
        state.context = config.get().diff.context
      else
        state.context = 99999
      end
      local file = state.files and state.files[state.current_file]
      if not file then return end
      local ld, rd = M.render_file_diff(layout.main_buf, file, state.mr, state.discussions, state.context)
      state.line_data_cache[state.current_file] = ld
      state.row_disc_cache[state.current_file] = rd
    end
    vim.api.nvim_win_set_cursor(layout.main_win, { math.min(cursor[1], vim.api.nvim_buf_line_count(layout.main_buf)), 0 })
  end)

  -- Refresh
  map(main_buf, "n", "R", function()
    M.open(state.mr, nil)
  end)
  map(sidebar_buf, "n", "R", function()
    M.open(state.mr, nil)
  end)

  -- Back to detail view
  local function back()
    local split = require("glab_review.ui.split")
    split.close(layout)
    local detail = require("glab_review.mr.detail")
    detail.open(state.mr)
  end
  map(main_buf, "n", "s", back)
  map(sidebar_buf, "n", "s", back)

  -- Quit
  local function quit()
    local split = require("glab_review.ui.split")
    split.close(layout)
    pcall(vim.api.nvim_buf_delete, layout.main_buf, { force = true })
  end
  map(main_buf, "n", "q", quit)
  map(sidebar_buf, "n", "q", quit)

  -- Sidebar: <CR> to select file or toggle directory
  map(sidebar_buf, "n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(layout.sidebar_win)
    local row = cursor[1]
    local entry = state.sidebar_row_map and state.sidebar_row_map[row]
    if not entry then return end

    if entry.type == "dir" then
      if not state.collapsed_dirs then state.collapsed_dirs = {} end
      if state.collapsed_dirs[entry.path] then
        state.collapsed_dirs[entry.path] = nil
      else
        state.collapsed_dirs[entry.path] = true
      end
      M.render_sidebar(layout.sidebar_buf, state)
      -- Keep cursor on the same directory row after re-render
      pcall(vim.api.nvim_win_set_cursor, layout.sidebar_win, { row, 0 })
    elseif entry.type == "file" then
      if state.scroll_mode then
        for _, sec in ipairs(state.file_sections) do
          if sec.file_idx == entry.idx then
            state.current_file = entry.idx
            M.render_sidebar(layout.sidebar_buf, state)
            vim.api.nvim_win_set_cursor(layout.main_win, { sec.start_line, 0 })
            vim.api.nvim_set_current_win(layout.main_win)
            return
          end
        end
      else
        state.current_file = entry.idx
        M.render_sidebar(layout.sidebar_buf, state)
        local line_data, row_disc = M.render_file_diff(
          layout.main_buf, state.files[entry.idx], state.mr, state.discussions, state.context)
        state.line_data_cache[entry.idx] = line_data
        state.row_disc_cache[entry.idx] = row_disc
        vim.api.nvim_set_current_win(layout.main_win)
      end
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

  -- Sync sidebar highlight with current file as cursor moves in scroll mode
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = main_buf,
    callback = function()
      if not state.scroll_mode or #state.file_sections == 0 then return end
      local file_idx = current_file_from_cursor(layout, state)
      if file_idx ~= state.current_file then
        state.current_file = file_idx
        M.render_sidebar(layout.sidebar_buf, state)
      end
    end,
  })
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

  local config = require("glab_review.config")
  local cfg = config.get()
  local state = {
    mr = mr,
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
  }

  M.render_sidebar(layout.sidebar_buf, state)

  if #files > 0 then
    if state.scroll_mode then
      local result = M.render_all_files(layout.main_buf, files, mr, state.discussions, state.context, state.file_contexts)
      state.file_sections = result.file_sections
      state.scroll_line_data = result.line_data
      state.scroll_row_disc = result.row_discussions
    else
      local line_data, row_disc = M.render_file_diff(layout.main_buf, files[1], mr, state.discussions, state.context)
      state.line_data_cache[1] = line_data
      state.row_disc_cache[1] = row_disc
    end
  else
    vim.bo[layout.main_buf].modifiable = true
    vim.api.nvim_buf_set_lines(layout.main_buf, 0, -1, false, { "No diffs found." })
    vim.bo[layout.main_buf].modifiable = false
  end

  M.setup_keymaps(layout, state)
  vim.api.nvim_set_current_win(layout.main_win)
end

return M
