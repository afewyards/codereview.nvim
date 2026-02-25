local M = {}

local function parse_iso_time(iso_str)
  if not iso_str then return nil end
  local y, mo, d, h, mi, s = iso_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):?(%d*)")
  if not y then return nil end
  return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) or 0 })
end

local function format_time_relative(iso_str)
  if not iso_str then return "" end
  local ts = parse_iso_time(iso_str)
  if not ts then return "" end
  local diff = os.time() - ts
  if diff < 60 then return "just now" end
  if diff < 3600 then return math.floor(diff / 60) .. "m ago" end
  if diff < 86400 then return math.floor(diff / 3600) .. "h ago" end
  if diff < 86400 * 30 then return math.floor(diff / 86400) .. "d ago" end
  local mo, d = iso_str:match("%d+-(%d+)-(%d+)")
  return mo and (mo .. "/" .. d) or ""
end

local function wrap_text(text, width)
  local markdown = require("codereview.ui.markdown")
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

local function md_virt_line(prefix, text, base_hl)
  local markdown = require("codereview.ui.markdown")
  local segs = markdown.parse_inline(text, base_hl)
  local line = {}
  -- Support single chunk {"text","hl"} or multiple {{"text","hl"},{"text","hl"}}
  if type(prefix[1]) == "string" then
    line[1] = prefix
  else
    vim.list_extend(line, prefix)
  end
  vim.list_extend(line, segs)
  return line
end

function M.is_resolved(discussion)
  if discussion.resolved ~= nil then return discussion.resolved end
  local note = discussion.notes and discussion.notes[1]
  return note and note.resolved
end

--- Build virtual lines for a comment thread (Bold Card style).
--- @param disc table  the discussion
--- @param opts table  { sel_idx?, current_user?, outdated?, editing_note?, spacer_height?, comment_width? }
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
  local comment_width = opts.comment_width or 60
  local gutter = opts.gutter or 0
  local pad = string.rep(" ", gutter)

  local notes = disc.notes
  if not notes or #notes == 0 then return { virt_lines = {}, spacer_offset = nil } end

  local editing_this = editing_note and editing_note.disc_id == disc.id
  local editing_note_idx = editing_this and editing_note.note_idx or nil

  local first = notes[1]
  local resolved = M.is_resolved(disc)
  local is_pending = disc.is_optimistic
  local is_err = disc.is_failed

  local bdr = is_err and "CodeReviewCommentFailed"
    or is_pending and "CodeReviewCommentPending"
    or "CodeReviewCommentBorder"
  local aut = is_err and "CodeReviewCommentFailed"
    or is_pending and "CodeReviewCommentPending"
    or "CodeReviewCommentAuthor"
  local body_hl = is_err and "CodeReviewCommentFailed"
    or is_pending and "CodeReviewCommentPending"
    or resolved and "CodeReviewComment" or "CodeReviewCommentUnresolved"
  local status_hl = is_err and "CodeReviewCommentFailed"
    or is_pending and "CodeReviewCommentPending"
    or resolved and "CodeReviewCommentResolved" or "CodeReviewCommentUnresolved"

  local time_str = format_time_relative(first.created_at)
  local header_meta = time_str ~= "" and (" · " .. time_str) or ""
  local header_text = "@" .. first.author
  local outdated_str = outdated and " Outdated" or ""

  local virt_lines = {}
  local spacer_offset = nil

  -- Helper: build prefix chunks for a line. When selected, prepend ██ in status_hl
  -- then remaining pad + suffix in suffix_hl. When not selected, pad + suffix in suffix_hl.
  local function sel_prefix(is_sel, suffix, suffix_hl)
    if is_sel then
      return {
        { "██", status_hl },
        { string.rep(" ", math.max(0, gutter - 2)) .. suffix, suffix_hl },
      }
    else
      return { pad .. suffix, suffix_hl }
    end
  end

  -- Header: ┏ @author · 2h ago                       ● Unresolved
  local n1_sel = (sel_idx == 1)

  local header_chunks = {}
  if n1_sel then
    table.insert(header_chunks, { "██", status_hl })
    table.insert(header_chunks, { string.rep(" ", math.max(0, gutter - 2)) .. "┏ ", bdr })
  else
    table.insert(header_chunks, { pad .. "┏ ", bdr })
  end
  table.insert(header_chunks, { header_text, aut })
  table.insert(header_chunks, { header_meta, bdr })

  if outdated_str ~= "" then
    table.insert(header_chunks, { outdated_str, "CodeReviewCommentOutdated" })
  end

  if is_err then
    local status_text = " Failed"
    local fill = math.max(0, 62 - #header_text - #header_meta - #outdated_str - #status_text)
    table.insert(header_chunks, { string.rep(" ", fill), bdr })
    table.insert(header_chunks, { status_text, bdr })
  elseif is_pending then
    local status_text = " Posting…"
    local fill = math.max(0, 62 - #header_text - #header_meta - #outdated_str - #status_text)
    table.insert(header_chunks, { string.rep(" ", fill), bdr })
    table.insert(header_chunks, { status_text, bdr })
  else
    local dot = resolved and "○ " or "● "
    local dot_hl = resolved and "CodeReviewStatusResolved" or "CodeReviewStatusUnresolved"
    local label = resolved and "Resolved" or "Unresolved"
    local fill = math.max(0, 62 - #header_text - #header_meta - #outdated_str - #dot - #label)
    table.insert(header_chunks, { string.rep(" ", fill), bdr })
    table.insert(header_chunks, { dot, dot_hl })
    table.insert(header_chunks, { label, status_hl })
  end

  table.insert(virt_lines, header_chunks)

  -- Body lines (or spacer when editing this note)
  if editing_note_idx == 1 then
    spacer_offset = #virt_lines
    for _ = 1, spacer_height do
      if n1_sel then
        table.insert(virt_lines, { { "██", status_hl }, { string.rep(" ", math.max(0, gutter - 2)) .. "┃" .. string.rep(" ", 61), bdr } })
      else
        table.insert(virt_lines, { { pad .. "┃" .. string.rep(" ", 61), bdr } })
      end
    end
  else
    for _, bl in ipairs(wrap_text(first.body, comment_width)) do
      local prefix = sel_prefix(n1_sel, "┃ ", bdr)
      table.insert(virt_lines, md_virt_line(prefix, bl, body_hl))
    end
  end

  -- Replies
  for i = 2, #notes do
    local reply = notes[i]
    if not reply.system then
      local rt = format_time_relative(reply.created_at)
      local rmeta = rt ~= "" and (" · " .. rt) or ""
      local ri_sel = (sel_idx == i)
      if editing_note_idx == i then
        spacer_offset = #virt_lines
        for _ = 1, spacer_height do
          if ri_sel then
            table.insert(virt_lines, { { "██", status_hl }, { string.rep(" ", math.max(0, gutter - 2)) .. "┃" .. string.rep(" ", 61), bdr } })
          else
            table.insert(virt_lines, { { pad .. "┃" .. string.rep(" ", 61), bdr } })
          end
        end
      else
        -- Separator line
        if ri_sel then
          table.insert(virt_lines, { { "██", status_hl }, { string.rep(" ", math.max(0, gutter - 2)) .. "┃", bdr } })
        else
          table.insert(virt_lines, { { pad .. "┃", bdr } })
        end
        -- Reply header
        local reply_header = {}
        if ri_sel then
          table.insert(reply_header, { "██", status_hl })
          table.insert(reply_header, { string.rep(" ", math.max(0, gutter - 2)) .. "┃  ↪ ", bdr })
        else
          table.insert(reply_header, { pad .. "┃  ↪ ", bdr })
        end
        table.insert(reply_header, { "@" .. reply.author, aut })
        table.insert(reply_header, { rmeta, bdr })
        table.insert(virt_lines, reply_header)
        -- Reply body
        for _, rl in ipairs(wrap_text(reply.body, 58)) do
          local prefix = sel_prefix(ri_sel, "┃    ", bdr)
          table.insert(virt_lines, md_virt_line(prefix, rl, body_hl))
        end
      end
    end
  end

  -- Footer
  local footer_content
  if is_err then
    footer_content = "gR:retry  D:discard"
  elseif is_pending then
    footer_content = "posting…"
  elseif sel_idx and not editing_this then
    local sel_note = notes[sel_idx]
    if sel_note and current_user and sel_note.author == current_user then
      footer_content = "r:reply  gt:un/resolve  e:edit  x:delete"
    else
      footer_content = "r:reply  gt:un/resolve"
    end
  end

  if footer_content then
    local footer_fill = math.max(0, 62 - #footer_content - 1)
    table.insert(virt_lines, {
      { pad .. "┗ ", bdr },
      { footer_content, bdr },
      { " " .. string.rep("━", footer_fill), bdr },
    })
  else
    table.insert(virt_lines, { { pad .. "┗━━", bdr } })
  end

  return { virt_lines = virt_lines, spacer_offset = spacer_offset }
end

M.format_time_relative = format_time_relative

-- Export helpers needed by diff.lua for AI suggestion rendering
M.wrap_text = wrap_text
M.md_virt_line = md_virt_line

return M
