-- lua/codereview/pipeline/ansi.lua
-- Parse ANSI SGR escape codes into plain text + Neovim highlight spans.
local M = {}

-- Basic ANSI color names (0-7)
local BASIC_FG = {
  [30] = "Black", [31] = "Red", [32] = "Green", [33] = "Yellow",
  [34] = "Blue", [35] = "Magenta", [36] = "Cyan", [37] = "White",
}

local BASIC_BG = {
  [40] = "Black", [41] = "Red", [42] = "Green", [43] = "Yellow",
  [44] = "Blue", [45] = "Magenta", [46] = "Cyan", [47] = "White",
}

-- Map basic color names to hex values for highlight groups
local COLOR_HEX = {
  Black = "#000000", Red = "#f7768e", Green = "#9ece6a", Yellow = "#e0af68",
  Blue = "#7aa2f7", Magenta = "#bb9af7", Cyan = "#7dcfff", White = "#c0caf5",
}

-- Cache for dynamic highlight groups
local hl_cache = {}

local function get_or_create_hl(attrs)
  local key = vim.inspect(attrs)
  if hl_cache[key] then return hl_cache[key] end
  local name = "CodeReviewAnsi_" .. (#hl_cache + 1)
  vim.api.nvim_set_hl(0, name, attrs)
  hl_cache[name] = name
  hl_cache[key] = name
  return name
end

local function color_to_hex(r, g, b)
  return string.format("#%02x%02x%02x", r, g, b)
end

-- Convert 8-bit color index to hex
local function color256_to_hex(n)
  if n < 8 then
    local names = { "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White" }
    return COLOR_HEX[names[n + 1]]
  elseif n < 16 then
    -- Bright colors
    local bright = {
      "#414868", "#f7768e", "#9ece6a", "#e0af68",
      "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
    }
    return bright[n - 8 + 1]
  elseif n < 232 then
    -- 6x6x6 color cube
    local idx = n - 16
    local b = idx % 6
    local g = math.floor(idx / 6) % 6
    local r = math.floor(idx / 36)
    return color_to_hex(r * 51, g * 51, b * 51)
  else
    -- Grayscale ramp
    local v = (n - 232) * 10 + 8
    return color_to_hex(v, v, v)
  end
end

local function build_hl_attrs(state)
  local attrs = {}
  if state.bold then attrs.bold = true end
  if state.italic then attrs.italic = true end
  if state.underline then attrs.underline = true end
  if state.strikethrough then attrs.strikethrough = true end
  if state.fg then attrs.fg = state.fg end
  if state.bg then attrs.bg = state.bg end
  return attrs
end

local function parse_sgr(params, state)
  local codes = {}
  for c in (params or "0"):gmatch("(%d+)") do
    table.insert(codes, tonumber(c))
  end

  local i = 1
  while i <= #codes do
    local c = codes[i]
    if c == 0 then
      state.bold = nil; state.italic = nil; state.underline = nil
      state.strikethrough = nil; state.fg = nil; state.bg = nil
    elseif c == 1 then state.bold = true
    elseif c == 3 then state.italic = true
    elseif c == 4 then state.underline = true
    elseif c == 9 then state.strikethrough = true
    elseif c == 22 then state.bold = nil
    elseif c == 23 then state.italic = nil
    elseif c == 24 then state.underline = nil
    elseif c == 29 then state.strikethrough = nil
    elseif BASIC_FG[c] then
      state.fg = COLOR_HEX[BASIC_FG[c]]
    elseif BASIC_BG[c] then
      state.bg = COLOR_HEX[BASIC_BG[c]]
    elseif c == 38 and codes[i+1] == 5 and codes[i+2] then
      state.fg = color256_to_hex(codes[i+2]); i = i + 2
    elseif c == 48 and codes[i+1] == 5 and codes[i+2] then
      state.bg = color256_to_hex(codes[i+2]); i = i + 2
    elseif c == 38 and codes[i+1] == 2 and codes[i+2] and codes[i+3] and codes[i+4] then
      state.fg = color_to_hex(codes[i+2], codes[i+3], codes[i+4]); i = i + 4
    elseif c == 48 and codes[i+1] == 2 and codes[i+2] and codes[i+3] and codes[i+4] then
      state.bg = color_to_hex(codes[i+2], codes[i+3], codes[i+4]); i = i + 4
    elseif c == 39 then state.fg = nil
    elseif c == 49 then state.bg = nil
    end
    i = i + 1
  end
end

--- Parse a string containing ANSI escape codes.
--- @param input string  Raw text with ANSI escapes
--- @return table  { lines: string[], highlights: { line, col_start, col_end, hl_group }[] }
function M.parse(input)
  local lines = {}
  local highlights = {}
  local state = {}
  local current_line = ""
  local col = 0
  local line_num = 1
  local span_start = nil
  local span_attrs = nil

  local pos = 1
  local len = #input

  while pos <= len do
    local esc_start = input:find("\27", pos, true)

    if not esc_start or esc_start > pos then
      -- Plain text before next escape (or rest of string)
      local chunk = input:sub(pos, esc_start and esc_start - 1 or len)
      -- Split on newlines
      for i = 1, #chunk do
        local ch = chunk:sub(i, i)
        if ch == "\n" then
          -- End current span
          if span_start and col > span_start then
            local attrs = build_hl_attrs(span_attrs)
            if next(attrs) then
              local hl_group = get_or_create_hl(attrs)
              table.insert(highlights, {
                line = line_num, col_start = span_start, col_end = col, hl_group = hl_group,
              })
            end
          end
          table.insert(lines, current_line)
          current_line = ""
          line_num = line_num + 1
          col = 0
          -- Resume span on new line if state is active
          if next(state) then
            span_start = 0
            span_attrs = vim.deepcopy(state)
          else
            span_start = nil
            span_attrs = nil
          end
        else
          current_line = current_line .. ch
          col = col + 1
        end
      end
      pos = esc_start or (len + 1)
    end

    if esc_start then
      -- Try to match SGR: ESC [ <params> m
      local sgr_params, sgr_end = input:match("^%[([%d;]*)m()", esc_start + 1)
      if sgr_params then
        -- End current span before state change
        if span_start and col > span_start then
          local attrs = build_hl_attrs(span_attrs)
          if next(attrs) then
            local hl_group = get_or_create_hl(attrs)
            table.insert(highlights, {
              line = line_num, col_start = span_start, col_end = col, hl_group = hl_group,
            })
          end
        end

        parse_sgr(sgr_params, state)

        -- Start new span if state is active
        if next(state) then
          span_start = col
          span_attrs = vim.deepcopy(state)
        else
          span_start = nil
          span_attrs = nil
        end

        pos = sgr_end
      else
        -- Non-SGR escape: try to skip CSI (ESC [ ... final_byte)
        local csi_end = input:match("^%[[%d;]*[A-Za-z]()", esc_start + 1)
        if csi_end then
          pos = csi_end
        else
          -- OSC: ESC ] ... (BEL or ST)
          local osc_end = input:match("^%].-[\7\27]()", esc_start + 1)
          if osc_end then
            pos = osc_end
          else
            -- Skip the ESC character
            pos = esc_start + 1
          end
        end
      end
    end
  end

  -- Flush last span
  if span_start and col > span_start then
    local attrs = build_hl_attrs(span_attrs)
    if next(attrs) then
      local hl_group = get_or_create_hl(attrs)
      table.insert(highlights, {
        line = line_num, col_start = span_start, col_end = col, hl_group = hl_group,
      })
    end
  end

  -- Flush last line
  table.insert(lines, current_line)

  return { lines = lines, highlights = highlights }
end

--- Reset the highlight cache (useful for testing).
function M.reset_cache()
  hl_cache = {}
end

return M
