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
  -- Only require structural chars ([, ](url)) to be unclaimed; label may contain code/bold.
  pos = 1
  while pos <= len do
    local ls, le = text:find("%[([^%]]+)%]%([^%)]+%)", pos)
    if not ls then break end
    local bracket_end = text:find("%]", ls)
    if bracket_end and fmt[ls] == base_hl and range_is_base(bracket_end, le) then
      fmt[ls] = nil -- strip [
      for i = ls + 1, bracket_end - 1 do
        if fmt[i] == base_hl then fmt[i] = hl("CodeReviewCommentLink") end
      end
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

-- Helper: flush collected code_lines into result (used by fenced code block handling)
local function flush_code_block(result, code_lines, code_lang)
  if #code_lines == 0 then return end
  local code_start_row = #result.lines
  for _, cl in ipairs(code_lines) do
    local row = #result.lines
    local padded = "  " .. cl
    table.insert(result.lines, padded)
    table.insert(result.highlights, { row, 0, #padded, "CodeReviewMdCodeBlock" })
  end
  table.insert(result.code_blocks, {
    start_row = code_start_row,
    end_row = code_start_row + #code_lines - 1,
    lang = code_lang,
    text = table.concat(code_lines, "\n"),
    indent = 2,
  })
end

-- ─── Table rendering ─────────────────────────────────────────────────────────

-- Split a pipe-table row into trimmed cell strings.
-- The outer | delimiters are consumed; cells are trimmed of whitespace.
-- e.g. "| A | B |" -> {"A", "B"}
-- e.g. "| |"       -> {""}   (one empty cell)
local function parse_table_row(line)
  local cells = {}
  local s = line:match("^%s*(.-)%s*$") or line
  s = s:match("^|(.-)%s*|?$") or s
  for cell in (s .. "|"):gmatch("([^|]*)|") do
    table.insert(cells, cell:match("^%s*(.-)%s*$"))
  end
  if #cells > 1 and cells[#cells] == "" then
    table.remove(cells)
  end
  return cells
end

-- Parse separator cell into alignment: "left", "right", or "center"
local function parse_alignment(sep_cell)
  local s = sep_cell:match("^%s*(.-)%s*$")
  local has_left  = s:sub(1, 1) == ":"
  local has_right = s:sub(-1) == ":"
  if has_left and has_right then return "center" end
  if has_right then return "right" end
  return "left"
end

-- Word-wrap text to fit within max_width. Returns list of strings.
local function word_wrap(text, max_width)
  if #text <= max_width then return { text } end
  local lines = {}
  local current = ""
  for word in text:gmatch("%S+") do
    if current == "" then
      if #word > max_width then
        while #word > max_width do
          table.insert(lines, word:sub(1, max_width))
          word = word:sub(max_width + 1)
        end
        current = word
      else
        current = word
      end
    elseif #current + 1 + #word <= max_width then
      current = current .. " " .. word
    else
      table.insert(lines, current)
      if #word > max_width then
        while #word > max_width do
          table.insert(lines, word:sub(1, max_width))
          word = word:sub(max_width + 1)
        end
        current = word
      else
        current = word
      end
    end
  end
  if current ~= "" then table.insert(lines, current) end
  if #lines == 0 then return { "" } end
  return lines
end

-- Pad text to exactly width chars with the given alignment.
local function pad_cell(text, width, align)
  local len = #text
  if len >= width then return text:sub(1, width) end
  local pad = width - len
  if align == "right" then
    return string.rep(" ", pad) .. text
  elseif align == "center" then
    local lp = math.floor(pad / 2)
    return string.rep(" ", lp) .. text .. string.rep(" ", pad - lp)
  else
    return text .. string.rep(" ", pad)
  end
end

-- Process cell text through inline parser for table rendering.
-- Returns display text (markdown stripped) and per-byte highlight array.
local function process_cell_inline(text, base_hl)
  if not text or text == "" then return "", {} end
  local segs = M.parse_inline(text, base_hl)
  local display = ""
  local char_hl = {}
  for _, seg in ipairs(segs) do
    for i = 1, #seg[1] do
      table.insert(char_hl, seg[2])
    end
    display = display .. seg[1]
  end
  return display, char_hl
end

-- Get per-wrapped-line highlight slices from the display text's char_hl.
-- Tracks character offsets through word_wrap boundaries.
local function wrapped_hl_slices(display, char_hl, wrapped, base_hl)
  local slices = {}
  local offset = 0
  for li, wline in ipairs(wrapped) do
    if li > 1 then
      while offset < #display and display:sub(offset + 1, offset + 1):match("%s") do
        offset = offset + 1
      end
    end
    local slice = {}
    for i = 1, #wline do
      slice[i] = char_hl[offset + i] or base_hl
    end
    table.insert(slices, slice)
    offset = offset + #wline
  end
  return slices
end

-- Render a pipe table from raw lines with cell wrapping and alignment.
-- Returns { lines = {...}, highlights = {...} } with row indices starting at start_row.
local function render_table(tbl_lines, base_hl, start_row, opts)
  local result = { lines = {}, highlights = {} }
  if #tbl_lines < 2 then return result end

  local header_cells = parse_table_row(tbl_lines[1])
  local num_cols = #header_cells
  if num_cols == 0 then return result end

  -- Parse separator row for alignments
  local sep_cells = parse_table_row(tbl_lines[2])
  local alignments = {}
  for ci = 1, num_cols do
    alignments[ci] = sep_cells[ci] and parse_alignment(sep_cells[ci]) or "left"
  end

  -- Parse data rows; pad short rows with empty cells
  local data_rows = {}
  for li = 3, #tbl_lines do
    local row_cells = parse_table_row(tbl_lines[li])
    local padded = {}
    for ci = 1, num_cols do padded[ci] = row_cells[ci] or "" end
    table.insert(data_rows, padded)
  end

  -- Pre-process cells: strip markdown syntax, get display text + per-char highlights
  local header_proc = {}
  for ci = 1, num_cols do
    local d, ch = process_cell_inline(header_cells[ci], base_hl)
    header_proc[ci] = { display = d, char_hl = ch }
  end

  local data_proc = {}
  for ri, row in ipairs(data_rows) do
    data_proc[ri] = {}
    for ci = 1, num_cols do
      local d, ch = process_cell_inline(row[ci], base_hl)
      data_proc[ri][ci] = { display = d, char_hl = ch }
    end
  end

  -- Calculate natural column widths from display text (min 3)
  local col_widths = {}
  for ci = 1, num_cols do
    col_widths[ci] = math.max(3, #header_proc[ci].display)
    for ri = 1, #data_proc do
      col_widths[ci] = math.max(col_widths[ci], #data_proc[ri][ci].display)
    end
  end

  -- Content budget: subtract border/padding overhead (each col: "│ " + " " = 3 chars, plus final "│")
  local table_width = opts.width or vim.api.nvim_win_get_width(0)
  local available = table_width - (3 * num_cols + 1)

  -- Per-column cap
  local max_col = math.max(5, math.floor(available / num_cols))
  for ci = 1, num_cols do
    col_widths[ci] = math.min(col_widths[ci], max_col)
  end

  -- Shrink widest columns first if total exceeds budget
  local function sum_widths()
    local s = 0
    for ci = 1, num_cols do s = s + col_widths[ci] end
    return s
  end

  while sum_widths() > available do
    local max_w = 0
    for ci = 1, num_cols do
      if col_widths[ci] > max_w then max_w = col_widths[ci] end
    end
    if max_w <= 3 then break end  -- can't shrink further

    local second_max = 3
    for ci = 1, num_cols do
      if col_widths[ci] < max_w and col_widths[ci] > second_max then
        second_max = col_widths[ci]
      end
    end

    local count = 0
    for ci = 1, num_cols do
      if col_widths[ci] == max_w then count = count + 1 end
    end

    local excess = sum_widths() - available
    local full_save = (max_w - second_max) * count

    if full_save > excess then
      -- Partially reduce: only shrink enough to fit
      local reduce = math.ceil(excess / count)
      for ci = 1, num_cols do
        if col_widths[ci] == max_w then
          col_widths[ci] = math.max(3, col_widths[ci] - reduce)
        end
      end
    else
      -- Level all widest down to second-widest
      for ci = 1, num_cols do
        if col_widths[ci] == max_w then
          col_widths[ci] = math.max(3, second_max)
        end
      end
    end
  end

  -- Expand columns to fill available width
  local slack = available - sum_widths()
  if slack > 0 then
    local per = math.floor(slack / num_cols)
    local remainder = slack - per * num_cols
    for ci = 1, num_cols do
      col_widths[ci] = col_widths[ci] + per + (ci <= remainder and 1 or 0)
    end
  end

  local function make_border(left, mid, right, fill)
    local parts = {}
    for ci = 1, num_cols do
      table.insert(parts, string.rep(fill, col_widths[ci] + 2))
    end
    return left .. table.concat(parts, mid) .. right
  end

  local function emit_border(line_text, hl_group)
    local row = start_row + #result.lines
    table.insert(result.lines, line_text)
    table.insert(result.highlights, { row, 0, #line_text, hl_group })
  end

  -- Emit a data line with per-cell inline highlights.
  -- cells[ci] = { padded = "...", hl_slice = {...} or nil, content_offset = N }
  local function emit_data_line(cells, line_hl)
    local row = start_row + #result.lines
    local parts = {}
    for ci = 1, num_cols do
      table.insert(parts, " " .. cells[ci].padded .. " ")
    end
    local line_text = "│" .. table.concat(parts, "│") .. "│"
    table.insert(result.lines, line_text)

    if line_hl then
      table.insert(result.highlights, { row, 0, #line_text, line_hl })
    end

    -- Apply per-cell inline highlights (grouped by contiguous runs)
    local byte_pos = 4  -- "│ " = 3 + 1 bytes (0-indexed start of cell content)
    for ci = 1, num_cols do
      local cell = cells[ci]
      if cell.hl_slice and #cell.hl_slice > 0 then
        local content_start = byte_pos + cell.content_offset
        local i = 1
        while i <= #cell.hl_slice do
          local hl = cell.hl_slice[i]
          if hl ~= base_hl then
            local run_start = i
            while i <= #cell.hl_slice and cell.hl_slice[i] == hl do
              i = i + 1
            end
            table.insert(result.highlights, {
              row, content_start + run_start - 1, content_start + i - 1, hl,
            })
          else
            i = i + 1
          end
        end
      end
      byte_pos = byte_pos + col_widths[ci] + 5  -- " │ " = 1 + 3 + 1 bytes
    end
  end

  -- Compute content_offset within padded cell based on alignment
  local function content_offset_for_align(content_len, width, align)
    if align == "right" then return width - content_len end
    if align == "center" then return math.floor((width - content_len) / 2) end
    return 0
  end

  -- Emit top border
  emit_border(make_border("┌", "┬", "┐", "─"), "CodeReviewMdTableBorder")

  -- Emit header row (wrapped + aligned, with inline highlights)
  local header_wrapped = {}
  local header_hl_slices = {}
  local header_max_lines = 1
  for ci = 1, num_cols do
    local proc = header_proc[ci]
    local wrapped = word_wrap(proc.display, col_widths[ci])
    header_wrapped[ci] = wrapped
    header_hl_slices[ci] = wrapped_hl_slices(proc.display, proc.char_hl, wrapped, base_hl)
    header_max_lines = math.max(header_max_lines, #wrapped)
  end
  for li = 1, header_max_lines do
    local cells = {}
    for ci = 1, num_cols do
      local wtext = header_wrapped[ci][li] or ""
      cells[ci] = {
        padded = pad_cell(wtext, col_widths[ci], alignments[ci]),
        hl_slice = header_hl_slices[ci][li],
        content_offset = content_offset_for_align(#wtext, col_widths[ci], alignments[ci]),
      }
    end
    emit_data_line(cells, "CodeReviewMdTableHeader")
  end

  -- Emit separator
  emit_border(make_border("├", "┼", "┤", "─"), "CodeReviewMdTableBorder")

  -- Emit data rows (wrapped + aligned, with inline highlights)
  for ri = 1, #data_proc do
    local cell_wrapped = {}
    local cell_hl_slices = {}
    local row_max_lines = 1
    for ci = 1, num_cols do
      local proc = data_proc[ri][ci]
      local wrapped = word_wrap(proc.display, col_widths[ci])
      cell_wrapped[ci] = wrapped
      cell_hl_slices[ci] = wrapped_hl_slices(proc.display, proc.char_hl, wrapped, base_hl)
      row_max_lines = math.max(row_max_lines, #wrapped)
    end
    for li = 1, row_max_lines do
      local cells = {}
      for ci = 1, num_cols do
        local wtext = cell_wrapped[ci][li] or ""
        cells[ci] = {
          padded = pad_cell(wtext, col_widths[ci], alignments[ci]),
          hl_slice = cell_hl_slices[ci][li],
          content_offset = content_offset_for_align(#wtext, col_widths[ci], alignments[ci]),
        }
      end
      emit_data_line(cells, nil)
    end
  end

  -- Emit bottom border
  emit_border(make_border("└", "┴", "┘", "─"), "CodeReviewMdTableBorder")

  return result
end

-- Strip HTML tags from text, converting block tags to newlines and removing the rest.
local function strip_html(text)
  if not text then return text end
  -- Replace <br>, <br/>, <br /> with newline
  text = text:gsub("<br%s*/?>", "\n")
  -- Remove all remaining HTML tags
  text = text:gsub("<[^>]+>", "")
  return text
end

-- parse_blocks(text, base_hl, opts) -> { lines, highlights, code_blocks }
-- State machine with goto continue so future block handlers can skip the paragraph fallback.
function M.parse_blocks(text, base_hl, opts)
  opts = opts or {}
  local result = { lines = {}, highlights = {}, code_blocks = {} }
  if not text or text == "" then return result end

  text = strip_html(text)
  local raw_lines = M.to_lines(text)
  local i = 1
  local state = "normal"
  local code_lang = nil
  local code_lines = nil

  while i <= #raw_lines do
    local line = raw_lines[i]
    local row = #result.lines

    -- In code block: collect lines until closing fence
    if state == "in_code_block" then
      if line:match("^```$") then
        flush_code_block(result, code_lines, code_lang)
        state = "normal"
        code_lang = nil
        code_lines = nil
      else
        table.insert(code_lines, line)
      end
      goto continue
    end

    -- Code fence open: ```lang
    if state == "normal" then
      local fence_lang = line:match("^```(.*)")
      if fence_lang ~= nil then
        state = "in_code_block"
        code_lang = fence_lang ~= "" and fence_lang or nil
        code_lines = {}
        goto continue
      end
    end

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

    -- Horizontal rule: ---, ***, ___
    if state == "normal" then
      if line:match("^%-%-%-$") or line:match("^%*%*%*$") or line:match("^___$") then
        local width = opts.width or 70
        local rule = string.rep("─", width)
        table.insert(result.lines, rule)
        table.insert(result.highlights, { row, 0, #rule, "CodeReviewMdHr" })
        goto continue
      end
    end

    -- Unordered list: ^(%s*)([-*+]) (.+)
    if state == "normal" then
      local list_indent, list_marker, list_content = line:match("^(%s*)([-*+]) (.+)")
      if list_content then
        local indent_level = math.floor(#list_indent / 2)
        local bullets = { "•", "◦", "▪" }
        local bullet = bullets[math.min(indent_level + 1, #bullets)]
        local prefix = string.rep("  ", indent_level) .. bullet .. " "
        local segs = M.parse_inline(list_content, base_hl)
        local rendered_text, inline_hls = M.segments_to_extmarks(segs, row, base_hl)
        table.insert(result.lines, prefix .. rendered_text)
        -- Bullet highlight: byte offsets for the bullet character
        local bullet_start = #string.rep("  ", indent_level)
        local bullet_end = bullet_start + #bullet
        table.insert(result.highlights, { row, bullet_start, bullet_end, "CodeReviewMdListBullet" })
        -- Shift inline highlights by prefix length
        local offset = #prefix
        for _, hl in ipairs(inline_hls) do
          table.insert(result.highlights, { hl[1], hl[2] + offset, hl[3] + offset, hl[4] })
        end
        goto continue
      end
    end

    -- Blockquote: lines starting with "> " or bare ">"
    if state == "normal" and (line:match("^> ") or line == ">") then
      -- Collect all consecutive blockquote lines
      local bq_lines = {}
      while i <= #raw_lines and (raw_lines[i]:match("^> ") or raw_lines[i] == ">") do
        local inner = raw_lines[i]:match("^> ?(.*)") or ""
        table.insert(bq_lines, inner)
        i = i + 1
      end
      local inner_text = table.concat(bq_lines, "\n")
      local inner_result = M.parse_blocks(inner_text, base_hl, opts)
      local bq_indent = "  "
      local start_row = #result.lines
      for _, rl in ipairs(inner_result.lines) do
        local bq_row = #result.lines
        local padded = bq_indent .. rl
        table.insert(result.lines, padded)
        table.insert(result.highlights, { bq_row, 0, #padded, "CodeReviewMdBlockquote" })
      end
      -- Offset inner highlights
      local offset = #bq_indent
      for _, h in ipairs(inner_result.highlights) do
        table.insert(result.highlights, { start_row + h[1], h[2] + offset, h[3] + offset, h[4] })
      end
      -- Offset inner code_blocks
      for _, cb in ipairs(inner_result.code_blocks) do
        table.insert(result.code_blocks, {
          start_row = start_row + cb.start_row,
          end_row = start_row + cb.end_row,
          lang = cb.lang,
          text = cb.text,
          indent = cb.indent + offset,
        })
      end
      -- i already advanced past all bq lines; undo the ::continue:: increment
      i = i - 1
      goto continue
    end

    -- Table: line matching ^|.+|$ followed by separator ^|[-: |]+|$
    if state == "normal"
       and line:match("^|.+|%s*$")
       and i + 1 <= #raw_lines
       and raw_lines[i + 1]:match("^|[-:| ]+|%s*$") then
      -- Collect all consecutive pipe-table lines
      local tbl_lines = {}
      while i <= #raw_lines and raw_lines[i]:match("^|.+|%s*$") do
        table.insert(tbl_lines, raw_lines[i])
        i = i + 1
      end
      local tbl_result = render_table(tbl_lines, base_hl, #result.lines, opts)
      for _, l in ipairs(tbl_result.lines) do
        table.insert(result.lines, l)
      end
      for _, h in ipairs(tbl_result.highlights) do
        table.insert(result.highlights, h)
      end
      -- i already advanced; undo the ::continue:: increment
      i = i - 1
      goto continue
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

  -- Flush unclosed code fence
  if state == "in_code_block" and code_lines then
    flush_code_block(result, code_lines, code_lang)
  end

  return result
end

return M
