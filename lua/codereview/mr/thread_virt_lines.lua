local M = {}
local config = require("codereview.config")
local markdown = require("codereview.ui.markdown")

local function md_virt_line(prefix_chunk, text, base_hl)
  local segs = markdown.parse_inline(text, base_hl)
  local line = { prefix_chunk }
  vim.list_extend(line, segs)
  return line
end

local function wrap_text(text, width)
  local result = {}
  for _, paragraph in ipairs(vim.split(text or "", "\n")) do
    if paragraph == "" then
      table.insert(result, "")
    elseif #paragraph <= width then
      table.insert(result, paragraph)
    else
      local spans = markdown.find_spans(paragraph)
      local function in_span(pos)
        for _, r in ipairs(spans) do
          if pos > r[1] and pos < r[2] then return true end
        end
        return false
      end

      local line = ""
      local char_pos = 1
      for word in paragraph:gmatch("%S+") do
        local ws = paragraph:find("%S", char_pos)
        char_pos = ws + #word

        if line ~= "" and #line + #word + 1 > width then
          if #spans > 0 and in_span(ws - 1) then
            line = line .. " " .. word
          else
            table.insert(result, line)
            line = word
          end
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

function M.is_resolved(discussion)
  if discussion.resolved ~= nil then return discussion.resolved end
  local note = discussion.notes and discussion.notes[1]
  return note and note.resolved
end

--- Build virtual lines for a comment thread.
--- @param disc table  the discussion
--- @param opts table  { sel_idx?, current_user?, outdated?, editing_note?, spacer_height? }
---   editing_note: { disc_id, note_idx } — replaces that note's body with blank spacer lines
---   spacer_height: number of spacer lines to insert (default 0)
--- @return { virt_lines: table[], spacer_offset: number|nil }
function M.build(disc, opts)
  opts = opts or {}
  local sel_idx = opts.sel_idx
  local current_user = opts.current_user
  local outdated = opts.outdated
  local editing_note = opts.editing_note
  local spacer_height = opts.spacer_height or 0

  local notes = disc.notes
  if not notes or #notes == 0 then return { virt_lines = {}, spacer_offset = nil } end

  -- Determine if this disc is the one being edited
  local editing_this = editing_note and editing_note.disc_id == disc.id
  local editing_note_idx = editing_this and editing_note.note_idx or nil

  local first = notes[1]
  local resolved = M.is_resolved(disc)
  local is_pending = disc.is_optimistic
  local is_err = disc.is_failed

  local bdr = is_err and "CodeReviewCommentFailed" or is_pending and "CodeReviewCommentPending" or "CodeReviewCommentBorder"
  local aut = is_err and "CodeReviewCommentFailed" or is_pending and "CodeReviewCommentPending" or "CodeReviewCommentAuthor"
  local body_hl = is_err and "CodeReviewCommentFailed"
    or is_pending and "CodeReviewCommentPending"
    or resolved and "CodeReviewComment" or "CodeReviewCommentUnresolved"
  local status_hl = is_err and "CodeReviewCommentFailed"
    or is_pending and "CodeReviewCommentPending"
    or resolved and "CodeReviewCommentResolved" or "CodeReviewCommentUnresolved"
  local status_str = is_err and " Failed " or is_pending and " Posting… " or resolved and " Resolved " or " Unresolved "
  local outdated_str = outdated and " Outdated " or ""
  local time_str = format_time_short(first.created_at)
  local header_meta = time_str ~= "" and (" · " .. time_str) or ""
  local header_text = "@" .. first.author
  local fill = math.max(0, 62 - #header_text - #header_meta - #status_str - #outdated_str)

  local virt_lines = {}
  local spacer_offset = nil

  -- ┌ @author · 02/15 14:30 · Unresolved ─────────
  local n1_bdr = (sel_idx == 1) and "CodeReviewSelectedNote" or bdr
  local n1_aut = (sel_idx == 1) and "CodeReviewSelectedNote" or aut
  local n1_body_hl = (sel_idx == 1) and "CodeReviewSelectedNote" or body_hl
  local header_chunks = {
    { "  ┌ ", n1_bdr },
    { header_text, n1_aut },
    { header_meta, n1_bdr },
    { status_str, status_hl },
  }
  if outdated_str ~= "" then
    table.insert(header_chunks, { outdated_str, "CodeReviewCommentOutdated" })
  end
  table.insert(header_chunks, { string.rep("─", fill), n1_bdr })
  table.insert(virt_lines, header_chunks)

  -- Comment body (wrapped, full) — or spacers when editing this note
  if editing_note_idx == 1 then
    spacer_offset = #virt_lines  -- = 1 (after header)
    for _ = 1, spacer_height do
      table.insert(virt_lines, { { "  │" .. string.rep(" ", 61), bdr } })
    end
  else
    for _, bl in ipairs(wrap_text(first.body, config.get().diff.comment_width)) do
      table.insert(virt_lines, md_virt_line({ "  │ ", n1_bdr }, bl, n1_body_hl))
    end
  end

  -- Replies
  for i = 2, #notes do
    local reply = notes[i]
    if not reply.system then
      local rt = format_time_short(reply.created_at)
      local rmeta = rt ~= "" and (" · " .. rt) or ""
      local ri_bdr = (sel_idx == i) and "CodeReviewSelectedNote" or bdr
      local ri_aut = (sel_idx == i) and "CodeReviewSelectedNote" or aut
      local ri_body_hl = (sel_idx == i) and "CodeReviewSelectedNote" or body_hl
      if editing_note_idx == i then
        -- Skip separator + reply header + body; insert spacers in their place
        spacer_offset = #virt_lines
        for _ = 1, spacer_height do
          table.insert(virt_lines, { { "  │" .. string.rep(" ", 61), ri_bdr } })
        end
      else
        table.insert(virt_lines, { { "  │", ri_bdr } })
        table.insert(virt_lines, {
          { "  │  ↪ ", ri_bdr },
          { "@" .. reply.author, ri_aut },
          { rmeta, ri_bdr },
        })
        for _, rl in ipairs(wrap_text(reply.body, 58)) do
          table.insert(virt_lines, md_virt_line({ "  │    ", ri_bdr }, rl, ri_body_hl))
        end
      end
    end
  end

  -- └ footer ──────────────────────
  local footer_content
  if is_err then
    footer_content = "gR:retry  D:discard"
  elseif is_pending then
    footer_content = "posting…"
  elseif sel_idx then
    local sel_note = notes[sel_idx]
    if sel_note and current_user and sel_note.author == current_user then
      footer_content = "r:reply  gt:un/resolve  e:edit  x:delete"
    else
      footer_content = "r:reply  gt:un/resolve"
    end
  else
    footer_content = ""
  end
  local footer_fill = math.max(0, 62 - #footer_content - (footer_content ~= "" and 1 or 0))
  if footer_content ~= "" then
    table.insert(virt_lines, {
      { "  └ ", bdr },
      { footer_content, body_hl },
      { " " .. string.rep("─", footer_fill), bdr },
    })
  else
    table.insert(virt_lines, {
      { "  └" .. string.rep("─", 63), bdr },
    })
  end

  return { virt_lines = virt_lines, spacer_offset = spacer_offset }
end

-- Export helpers needed by diff.lua for AI suggestion rendering
M.wrap_text = wrap_text
M.md_virt_line = md_virt_line

return M
