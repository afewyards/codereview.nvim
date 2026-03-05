-- lua/codereview/pipeline/log_sections.lua
-- Parse CI job log traces into collapsible sections.
local M = {}

--- @class LogSection
--- @field title string
--- @field lines string[]
--- @field collapsed boolean
--- @field has_errors boolean

--- @class ParseResult
--- @field prefix string[]
--- @field sections LogSection[]

-- Red ANSI patterns that indicate errors
local ERROR_PATTERNS = {
  "\27%[31m", -- basic red
  "\27%[0;31m", -- reset + red
  "\27%[1;31m", -- bold red
}

local function has_red_ansi(line)
  for _, pat in ipairs(ERROR_PATTERNS) do
    if line:find(pat) then
      return true
    end
  end
  return false
end

--- Parse a raw trace string into sections.
--- @param trace string
--- @return ParseResult
function M.parse(trace)
  if trace == "" then
    return { prefix = {}, sections = {} }
  end
  local lines = {}
  for line in (trace .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end

  local prefix = {}
  local sections = {}
  local current = nil

  for _, line in ipairs(lines) do
    -- GitHub: ##[group]Title
    local gh_title = line:match("^##%[group%](.+)$")
    if gh_title then
      if current then
        table.insert(sections, current)
      end
      current = { title = gh_title, lines = {}, collapsed = true, has_errors = false }
      goto continue
    end

    -- GitHub: ##[endgroup]
    if line:match("^##%[endgroup%]$") then
      if current then
        table.insert(sections, current)
        current = nil
      end
      goto continue
    end

    -- GitLab: section_start
    local gl_title = line:match("^\27%[0Ksection_start:%d+%.%d+:[%w_]+\r\27%[0K(.+)$")
    if gl_title then
      if current then
        table.insert(sections, current)
      end
      current = { title = gl_title, lines = {}, collapsed = true, has_errors = false }
      goto continue
    end

    -- GitLab: section_end
    if line:match("^\27%[0Ksection_end:%d+%.%d+:[%w_]+") then
      if current then
        table.insert(sections, current)
        current = nil
      end
      goto continue
    end

    -- Content line
    if current then
      table.insert(current.lines, line)
      if not current.has_errors and has_red_ansi(line) then
        current.has_errors = true
      end
    else
      table.insert(prefix, line)
    end

    ::continue::
  end

  -- Flush unclosed section
  if current then
    table.insert(sections, current)
  end

  return { prefix = prefix, sections = sections }
end

return M
