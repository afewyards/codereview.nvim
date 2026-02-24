local M = {}

function M.strip_links(text)
  -- [label](url) -> label
  return text:gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1")
end

function M.to_lines(text)
  if not text then return {} end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  -- Remove trailing empty line from our split
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

function M.render_to_buf(buf, text, start_line)
  start_line = start_line or 0
  local lines = M.to_lines(text)
  vim.api.nvim_buf_set_lines(buf, start_line, start_line, false, lines)
  vim.bo[buf].filetype = "markdown"
  return #lines
end

function M.set_buf_markdown(buf)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].syntax = "markdown"
end

local HL_SUFFIX_MAP = {
  CodeReviewComment = "",
  CodeReviewCommentUnresolved = "Unresolved",
  CodeReviewSelectedNote = "SelectedNote",
}

-- ─── Flanking delimiter helpers ───────────────────────────────────────────────

-- Opening delimiter: char before must NOT be a word char, first char of inner
-- text must NOT be whitespace.
local function flanking_open(text, delim_start, delim_len)
  if delim_start > 1 then
    local before = text:sub(delim_start - 1, delim_start - 1)
    if before:match("[%w_]") then return false end
  end
  local inner_pos = delim_start + delim_len
  if inner_pos > #text then return false end
  if text:sub(inner_pos, inner_pos):match("%s") then return false end
  return true
end

-- Closing delimiter: char after must NOT be a word char, last char of inner
-- text must NOT be whitespace.
local function flanking_close(text, delim_end, delim_len)
  if delim_end < #text then
    local after = text:sub(delim_end + 1, delim_end + 1)
    if after:match("[%w_]") then return false end
  end
  local inner_pos = delim_end - delim_len
  if inner_pos < 1 then return false end
  if text:sub(inner_pos, inner_pos):match("%s") then return false end
  return true
end

-- ─── Public API ──────────────────────────────────────────────────────────────

-- Returns {{start_pos, end_pos}, ...} for all markdown spans in text.
-- Useful for callers that need to know span boundaries (e.g. wrap_text).
function M.find_spans(text)
  if not text or text == "" then return {} end
  local result = {}

  -- code spans
  local pos = 1
  while pos <= #text do
    local s, e = text:find("`(.-)`", pos)
    if not s then break end
    if e > s + 1 then table.insert(result, { s, e }) end
    pos = e + 1
  end

  -- links
  pos = 1
  while pos <= #text do
    local s, e = text:find("%[([^%]]+)%]%([^%)]+%)", pos)
    if not s then break end
    table.insert(result, { s, e })
    pos = e + 1
  end

  -- bold
  pos = 1
  while pos <= #text do
    local s, e = text:find("%*%*(.-)%*%*", pos)
    if not s then break end
    if e - s >= 4 and flanking_open(text, s, 2) and flanking_close(text, e, 2) then
      table.insert(result, { s, e })
    end
    pos = e + 1
  end

  -- strikethrough
  pos = 1
  while pos <= #text do
    local s, e = text:find("~~(.-)~~", pos)
    if not s then break end
    if e - s >= 4 and flanking_open(text, s, 2) and flanking_close(text, e, 2) then
      table.insert(result, { s, e })
    end
    pos = e + 1
  end

  -- italic
  pos = 1
  while pos <= #text do
    local s, e = text:find("%*([^%*]+)%*", pos)
    if not s then break end
    local before = s > 1 and text:sub(s - 1, s - 1) or ""
    local after = e < #text and text:sub(e + 1, e + 1) or ""
    if before ~= "*" and after ~= "*"
       and flanking_open(text, s, 1) and flanking_close(text, e, 1) then
      table.insert(result, { s, e })
      pos = e + 1
    else
      pos = s + 1
    end
  end

  return result
end

function M.parse_inline(text, base_hl)
  if not text or text == "" then return { { "", base_hl } } end
  if not HL_SUFFIX_MAP[base_hl] then return { { text, base_hl } } end

  local suffix = HL_SUFFIX_MAP[base_hl]
  local function hl(name) return name .. suffix end

  local len = #text
  -- Per-character format: each position gets a highlight or nil (= strip)
  local fmt = {}
  for i = 1, len do fmt[i] = base_hl end

  -- Helper: check if ALL positions in range still have base_hl
  local function range_is_base(s, e)
    for i = s, e do
      if fmt[i] ~= base_hl then return false end
    end
    return true
  end

  -- Pass 1: code spans `text` (highest priority, no flanking needed)
  local pos = 1
  while pos <= len do
    local cs, ce = text:find("`(.-)`", pos)
    if not cs then break end
    if ce > cs + 1 then -- inner text is non-empty
      fmt[cs] = nil -- strip opening backtick
      for i = cs + 1, ce - 1 do fmt[i] = hl("CodeReviewCommentCode") end
      fmt[ce] = nil -- strip closing backtick
    end
    pos = ce + 1
  end

  -- Pass 2: links [label](url) (no flanking needed)
  pos = 1
  while pos <= len do
    local ls, le = text:find("%[([^%]]+)%]%([^%)]+%)", pos)
    if not ls then break end
    -- Only process if the entire range hasn't been claimed by code spans
    local bracket_end = text:find("%]", ls)
    if bracket_end and range_is_base(ls, le) then
      fmt[ls] = nil -- strip [
      for i = ls + 1, bracket_end - 1 do fmt[i] = hl("CodeReviewCommentLink") end
      for i = bracket_end, le do fmt[i] = nil end -- strip ](url)
    end
    pos = le + 1
  end

  -- Pass 3: bold **text** (with flanking checks, can contain code/links)
  pos = 1
  while pos <= len do
    local bs, be = text:find("%*%*(.-)%*%*", pos)
    if not bs then break end
    if be - bs >= 4 -- inner text is non-empty (at least **x**)
       and flanking_open(text, bs, 2)
       and flanking_close(text, be, 2)
       -- Only process if the delimiter positions are still base_hl
       and fmt[bs] == base_hl and fmt[bs + 1] == base_hl
       and fmt[be - 1] == base_hl and fmt[be] == base_hl then
      -- Strip delimiters
      fmt[bs] = nil
      fmt[bs + 1] = nil
      fmt[be - 1] = nil
      fmt[be] = nil
      -- Apply bold to inner chars that still have base_hl
      for i = bs + 2, be - 2 do
        if fmt[i] == base_hl then
          fmt[i] = hl("CodeReviewCommentBold")
        end
        -- Leave code/link formatting untouched
      end
    end
    pos = be + 1
  end

  -- Pass 4: strikethrough ~~text~~ (with flanking checks, can contain code/links)
  pos = 1
  while pos <= len do
    local ss, se = text:find("~~(.-)~~", pos)
    if not ss then break end
    if se - ss >= 4
       and flanking_open(text, ss, 2)
       and flanking_close(text, se, 2)
       and fmt[ss] == base_hl and fmt[ss + 1] == base_hl
       and fmt[se - 1] == base_hl and fmt[se] == base_hl then
      fmt[ss] = nil
      fmt[ss + 1] = nil
      fmt[se - 1] = nil
      fmt[se] = nil
      for i = ss + 2, se - 2 do
        if fmt[i] == base_hl then
          fmt[i] = hl("CodeReviewCommentStrikethrough")
        end
      end
    end
    pos = se + 1
  end

  -- Pass 5: italic *text* (with flanking checks, skip ** neighbors)
  pos = 1
  while pos <= len do
    local is_, ie = text:find("%*([^%*]+)%*", pos)
    if not is_ then break end
    local before = is_ > 1 and text:sub(is_ - 1, is_ - 1) or ""
    local after = ie < len and text:sub(ie + 1, ie + 1) or ""
    if before ~= "*" and after ~= "*"
       and flanking_open(text, is_, 1)
       and flanking_close(text, ie, 1)
       and fmt[is_] == base_hl and fmt[ie] == base_hl then
      fmt[is_] = nil -- strip opening *
      fmt[ie] = nil -- strip closing *
      for i = is_ + 1, ie - 1 do
        if fmt[i] == base_hl then
          fmt[i] = hl("CodeReviewCommentItalic")
        end
      end
      pos = ie + 1
    else
      pos = is_ + 1
    end
  end

  -- Build segments by grouping adjacent chars with same highlight
  local segments = {}
  local seg_text = ""
  local seg_hl = nil
  for i = 1, len do
    if fmt[i] ~= nil then -- nil = stripped delimiter character
      if fmt[i] == seg_hl then
        seg_text = seg_text .. text:sub(i, i)
      else
        if seg_text ~= "" then
          table.insert(segments, { seg_text, seg_hl })
        end
        seg_text = text:sub(i, i)
        seg_hl = fmt[i]
      end
    end
  end
  if seg_text ~= "" then
    table.insert(segments, { seg_text, seg_hl })
  end

  if #segments == 0 then return { { text, base_hl } } end
  return segments
end

function M.segments_to_extmarks(segments, row, base_hl)
  local text = ""
  local highlights = {}
  for _, seg in ipairs(segments) do
    local start_col = #text
    text = text .. seg[1]
    if seg[2] ~= base_hl then
      table.insert(highlights, { row, start_col, #text, seg[2] })
    end
  end
  return text, highlights
end

-- parse_blocks(text, base_hl, opts) -> { lines, highlights, code_blocks }
-- State machine with goto continue so future block handlers can skip the paragraph fallback.
function M.parse_blocks(text, base_hl, opts)
  local result = { lines = {}, highlights = {}, code_blocks = {} }
  if not text or text == "" then return result end

  local raw_lines = M.to_lines(text)
  local i = 1
  local state = "normal" -- future states: "in_code_block", "in_table"

  while i <= #raw_lines do
    local line = raw_lines[i]
    local row = #result.lines

    -- Header: ^#{1,6} <content>
    if state == "normal" then
      local hashes, content = line:match("^(#+) (.+)")
      if hashes and #hashes <= 6 then
        local level = #hashes
        local segs = M.parse_inline(content, base_hl)
        local rendered_text, inline_hls = M.segments_to_extmarks(segs, row, base_hl)
        table.insert(result.lines, rendered_text)
        table.insert(result.highlights, { row, 0, #rendered_text, "CodeReviewMdH" .. level })
        for _, hl in ipairs(inline_hls) do
          table.insert(result.highlights, hl)
        end
        goto continue
      end
    end

    -- Ordered list: ^(%s*)(%d+)%. (.+)
    if state == "normal" then
      local ol_indent, ol_num, ol_content = line:match("^(%s*)(%d+)%. (.+)")
      if ol_content then
        local prefix = ol_indent .. ol_num .. ". "
        local segs = M.parse_inline(ol_content, base_hl)
        local rendered_text, inline_hls = M.segments_to_extmarks(segs, row, base_hl)
        table.insert(result.lines, prefix .. rendered_text)
        local offset = #prefix
        for _, hl in ipairs(inline_hls) do
          table.insert(result.highlights, { hl[1], hl[2] + offset, hl[3] + offset, hl[4] })
        end
        goto continue
      end
    end

    -- Paragraph fallback: all unrecognized lines in normal state
    if state == "normal" then
      local segs = M.parse_inline(line, base_hl)
      local rendered_text, hls = M.segments_to_extmarks(segs, row, base_hl)
      table.insert(result.lines, rendered_text)
      for _, hl in ipairs(hls) do
        table.insert(result.highlights, hl)
      end
    end

    ::continue::
    i = i + 1
  end

  return result
end

return M
