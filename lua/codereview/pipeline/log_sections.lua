-- lua/codereview/pipeline/log_sections.lua
-- Parse CI job log traces into collapsible sections.
local M = {}

local log = require("codereview.log")

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

--- Strip ANSI escape sequences from a string.
local function strip_ansi(s)
  return s:gsub("\27%[[%d;]*m", "")
end

--- Parse a raw trace string into sections.
--- @param trace string
--- @return ParseResult
function M.parse(trace)
  if trace == "" then
    return { prefix = {}, sections = {} }
  end

  log.debug("log_sections.parse: trace length=" .. #trace)
  -- Log first 500 chars of raw trace for debugging marker format
  log.debug("log_sections.parse: raw trace start=" .. trace:sub(1, 500):gsub("\27", "<ESC>"):gsub("\r", "<CR>"))

  local lines = {}
  for line in (trace .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end

  log.debug("log_sections.parse: total lines=" .. #lines)

  local prefix = {}
  local sections = {}
  local current = nil

  for i, line in ipairs(lines) do
    -- Log lines that look like they might be section markers (contain "section_start" or "##[group")
    if
      line:find("section_start", 1, true)
      or line:find("section_end", 1, true)
      or line:find("##%[group")
      or line:find("##%[endgroup")
    then
      log.debug(
        "log_sections.parse: potential marker line " .. i .. "=" .. line:gsub("\27", "<ESC>"):gsub("\r", "<CR>")
      )
    end

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

    -- GitLab: section markers may appear bare or with leading ESC[0K,
    -- and section_end + section_start can be combined on a single line.
    -- Real format: section_end:TS:NAME\27[0Ksection_start:TS:NAME\27[0K\27[0K\27[36;1mTitle\27[0;m
    if line:find("section_start:", 1, true) or line:find("section_end:", 1, true) then
      -- Check for section_end (close current section)
      if line:find("section_end:", 1, true) then
        log.debug("log_sections.parse: MATCHED section_end")
        if current then
          table.insert(sections, current)
          current = nil
        end
      end

      -- Check for section_start (open new section) — extract title after the marker
      local gl_title = line:match("section_start:%d+[%.%d]*:[%w_%-%.]+\r?\27%[0K(.*)")
      if gl_title then
        -- Strip leading \27[0K sequences and ANSI color from title
        gl_title = gl_title:gsub("^\27%[0K", "")
        gl_title = strip_ansi(gl_title):gsub("%s+$", "")
        if gl_title == "" then
          gl_title = line:match("section_start:%d+[%.%d]*:([%w_%-%.]+)") or "section"
        end
        log.debug("log_sections.parse: MATCHED section_start title=" .. gl_title)
        current = { title = gl_title, lines = {}, collapsed = true, has_errors = false }
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

  log.debug(string.format("log_sections.parse: result prefix=%d sections=%d", #prefix, #sections))
  for si, s in ipairs(sections) do
    log.debug(
      string.format(
        "log_sections.parse: section[%d] title=%s lines=%d has_errors=%s",
        si,
        s.title,
        #s.lines,
        tostring(s.has_errors)
      )
    )
  end

  return { prefix = prefix, sections = sections }
end

return M
