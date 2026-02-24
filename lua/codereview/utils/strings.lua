--- String utilities for codereview.nvim
local M = {}

--- Truncate a string to max_len, appending an ellipsis if truncated.
---@param s string
---@param max_len number
---@return string
function M.truncate(s, max_len)
  if #s <= max_len then return s end
  return s:sub(1, max_len - 1) .. "…"
end

--- Strip leading and trailing whitespace.
---@param s string
---@return string
function M.trim(s)
  return s:match("^%s*(.-)%s*$")
end

--- Split a string by a delimiter pattern.
---@param s string
---@param sep string  Pattern to split on (e.g. "\n")
---@return string[]
function M.split(s, sep)
  local parts = {}
  for part in s:gmatch("([^" .. sep .. "]+)") do
    table.insert(parts, part)
  end
  return parts
end

--- Wrap text to a maximum line width, breaking on word boundaries.
---@param text string
---@param width number
---@return string
function M.wrap(text, width)
  local lines = {}
  for _, paragraph in ipairs(M.split(text, "\n")) do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      if #line + #word + 1 > width and #line > 0 then
        table.insert(lines, line)
        line = word
      else
        line = #line > 0 and (line .. " " .. word) or word
      end
    end
    if #line > 0 then table.insert(lines, line) end
  end
  return table.concat(lines, "\n")
end

--- Escape special Lua pattern characters in a string.
---@param s string
---@return string
function M.escape_pattern(s)
  return s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

--- Check whether a string starts with a given prefix.
---@param s string
---@param prefix string
---@return boolean
function M.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

--- Check whether a string ends with a given suffix.
---@param s string
---@param suffix string
---@return boolean
function M.ends_with(s, suffix)
  return suffix == "" or s:sub(-#suffix) == suffix
end

--- Pad a string on the right to reach the desired width.
---@param s string
---@param width number
---@param char? string  Padding character (default: space)
---@return string
function M.pad_right(s, width, char)
  char = char or " "
  if #s >= width then return s end
  return s .. string.rep(char, width - #s)
end

return M
