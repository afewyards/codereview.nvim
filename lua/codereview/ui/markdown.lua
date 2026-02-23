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
}

function M.parse_inline(text, base_hl)
  if not text or text == "" then return { { "", base_hl } } end
  if not HL_SUFFIX_MAP[base_hl] then return { { text, base_hl } } end

  local suffix = HL_SUFFIX_MAP[base_hl]
  local function hl(name) return name .. suffix end

  local spans = {}

  -- Helper: check if a new span overlaps any existing span
  local function overlaps_existing(s, e)
    for _, sp in ipairs(spans) do
      if s <= sp[2] and e >= sp[1] then return true end
    end
    return false
  end

  -- Pass 1: code spans (backtick) — highest priority
  local pos = 1
  while pos <= #text do
    local cs, ce = text:find("`(.-)`", pos)
    if not cs then break end
    local inner = text:sub(cs + 1, ce - 1)
    if #inner > 0 then
      table.insert(spans, { cs, ce, inner, hl("CodeReviewCommentCode") })
    end
    pos = ce + 1
  end

  -- Pass 2: links [label](url)
  pos = 1
  while pos <= #text do
    local ls, le, label = text:find("%[([^%]]+)%]%([^%)]+%)", pos)
    if not ls then break end
    if not overlaps_existing(ls, le) then
      table.insert(spans, { ls, le, label, hl("CodeReviewCommentLink") })
    end
    pos = le + 1
  end

  -- Note: ***triple-asterisk*** is not supported (would need nested bold+italic handling)
  -- Pass 3: bold **text**
  pos = 1
  while pos <= #text do
    local bs, be = text:find("%*%*(.-)%*%*", pos)
    if not bs then break end
    local inner = text:sub(bs + 2, be - 2)
    if #inner > 0 and not overlaps_existing(bs, be) then
      table.insert(spans, { bs, be, inner, hl("CodeReviewCommentBold") })
    end
    pos = be + 1
  end

  -- Pass 4: strikethrough ~~text~~
  pos = 1
  while pos <= #text do
    local ss, se = text:find("~~(.-)~~", pos)
    if not ss then break end
    local inner = text:sub(ss + 2, se - 2)
    if #inner > 0 and not overlaps_existing(ss, se) then
      table.insert(spans, { ss, se, inner, hl("CodeReviewCommentStrikethrough") })
    end
    pos = se + 1
  end

  -- Pass 5: italic *text* (single asterisk, not part of **)
  pos = 1
  while pos <= #text do
    local is_, ie = text:find("%*([^%*]+)%*", pos)
    if not is_ then break end
    local before = is_ > 1 and text:sub(is_ - 1, is_ - 1) or ""
    local after = ie < #text and text:sub(ie + 1, ie + 1) or ""
    if before ~= "*" and after ~= "*" then
      local inner = text:sub(is_ + 1, ie - 1)
      if #inner > 0 and not overlaps_existing(is_, ie) then
        table.insert(spans, { is_, ie, inner, hl("CodeReviewCommentItalic") })
      end
      pos = ie + 1
    else
      pos = is_ + 1
    end
  end

  if #spans == 0 then return { { text, base_hl } } end

  table.sort(spans, function(a, b) return a[1] < b[1] end)

  local segments = {}
  local cursor = 1
  for _, sp in ipairs(spans) do
    if sp[1] > cursor then
      table.insert(segments, { text:sub(cursor, sp[1] - 1), base_hl })
    end
    table.insert(segments, { sp[3], sp[4] })
    cursor = sp[2] + 1
  end
  if cursor <= #text then
    table.insert(segments, { text:sub(cursor), base_hl })
  end

  return segments
end

return M
