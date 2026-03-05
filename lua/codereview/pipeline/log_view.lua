-- lua/codereview/pipeline/log_view.lua
-- Secondary float for displaying job trace logs with ANSI rendering.
local M = {}

local ansi = require("codereview.pipeline.ansi")
local log_sections = require("codereview.pipeline.log_sections")

local ns = vim.api.nvim_create_namespace("codereview_pipeline_log")

local handle = nil

--- Build display lines from parsed sections.
--- @param parsed ParseResult
--- @param max_lines number?
--- @return table { lines: string[], highlights: table[], section_map: table }
function M.build_display(parsed, max_lines)
  local lines = {}
  local highlights = {}
  local section_map = {} -- row -> section index
  local total = 0

  -- Prefix lines
  for _, line in ipairs(parsed.prefix) do
    local p = ansi.parse(line)
    table.insert(lines, p.lines[1] or line)
    for _, hl in ipairs(p.highlights) do
      table.insert(highlights, vim.tbl_extend("force", hl, { line = #lines }))
    end
    total = total + 1
    if max_lines and total >= max_lines then
      return { lines = lines, highlights = highlights, section_map = section_map }
    end
  end

  -- Sections
  for si, section in ipairs(parsed.sections) do
    local row = #lines + 1
    if section.collapsed then
      local header = string.format("▸ %s (%d lines)", section.title, #section.lines)
      table.insert(lines, header)
      table.insert(highlights, {
        line = row,
        col_start = 0,
        col_end = #header,
        hl_group = "CodeReviewLogSectionHeader",
      })
      section_map[row] = si
      total = total + 1
    else
      local header = string.format("▾ %s", section.title)
      table.insert(lines, header)
      table.insert(highlights, {
        line = row,
        col_start = 0,
        col_end = #header,
        hl_group = "CodeReviewLogSectionHeader",
      })
      section_map[row] = si
      total = total + 1

      for _, content_line in ipairs(section.lines) do
        if max_lines and total >= max_lines then
          break
        end
        local p = ansi.parse(content_line)
        local text = "  " .. (p.lines[1] or content_line)
        table.insert(lines, text)
        for _, hl in ipairs(p.highlights) do
          table.insert(
            highlights,
            vim.tbl_extend("force", hl, {
              line = #lines,
              col_start = hl.col_start + 2,
              col_end = hl.col_end + 2,
            })
          )
        end
        total = total + 1
      end
    end
    if max_lines and total >= max_lines then
      break
    end
  end

  return { lines = lines, highlights = highlights, section_map = section_map }
end

--- Open a log view float for a job trace.
--- @param job table  normalized pipeline job
--- @param trace string  raw job log text
--- @param max_lines number?  truncation limit (default 5000)
--- @return table  handle { buf, win, close, closed, parsed, section_map }
function M.open(job, trace, max_lines)
  M.close()
  max_lines = max_lines or 5000

  local parsed = log_sections.parse(trace)

  -- Initial fold state: all collapsed except last + error sections
  for _, section in ipairs(parsed.sections) do
    section.collapsed = true
  end
  if #parsed.sections > 0 then
    parsed.sections[#parsed.sections].collapsed = false
  end
  for _, section in ipairs(parsed.sections) do
    if section.has_errors then
      section.collapsed = false
    end
  end

  local display = M.build_display(parsed, max_lines)
  local lines = display.lines

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "codereview_pipeline_log"

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Apply highlights
  for _, hl in ipairs(display.highlights) do
    if hl.line <= #lines then
      pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl_group, hl.line - 1, hl.col_start, hl.col_end)
    end
  end

  local width = math.min(120, math.floor(vim.o.columns * 0.8))
  local height = math.min(30, math.floor(vim.o.lines * 0.6))
  local win_row = math.floor((vim.o.lines - height) / 2)
  local win_col = math.floor((vim.o.columns - width) / 2)

  local title = string.format(" %s — %s ", job.name or "Job", job.status or "")

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = win_row,
    col = win_col,
    style = "minimal",
    border = "rounded",
    title = { { title, "CodeReviewFloatTitle" } },
    title_pos = "center",
    zindex = 60,
    footer = { { " q:close  <CR>:toggle ", "CodeReviewFloatFooter" } },
    footer_pos = "center",
  })

  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("number", true, { win = win })

  handle = { buf = buf, win = win, closed = false, parsed = parsed, section_map = display.section_map }

  function handle.close()
    if handle.closed then
      return
    end
    handle.closed = true
    pcall(vim.api.nvim_win_close, win, true)
  end

  -- Re-render helper
  local function rerender()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local old_si = handle.section_map[cursor[1]]

    local new_display = M.build_display(parsed, max_lines)
    handle.section_map = new_display.section_map

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_display.lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, hl in ipairs(new_display.highlights) do
      if hl.line <= #new_display.lines then
        pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl_group, hl.line - 1, hl.col_start, hl.col_end)
      end
    end

    -- Restore cursor to same section
    if old_si then
      local restore_rows = {}
      for r in pairs(new_display.section_map) do
        table.insert(restore_rows, r)
      end
      table.sort(restore_rows)
      for _, r in ipairs(restore_rows) do
        if new_display.section_map[r] == old_si then
          pcall(vim.api.nvim_win_set_cursor, win, { r, 0 })
          return
        end
      end
    end
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(cursor[1], #new_display.lines), 0 })
  end

  -- Keymaps
  local opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set("n", "q", handle.close, vim.tbl_extend("force", opts, { desc = "Close log" }))
  vim.keymap.set("n", "<Esc>", handle.close, vim.tbl_extend("force", opts, { desc = "Close log" }))

  vim.keymap.set("n", "<CR>", function()
    local cur_row = vim.api.nvim_win_get_cursor(win)[1]
    local si = handle.section_map[cur_row]
    if si and parsed.sections[si] then
      parsed.sections[si].collapsed = not parsed.sections[si].collapsed
      rerender()
    end
  end, vim.tbl_extend("force", opts, { desc = "Toggle section" }))

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      handle.close()
    end,
  })

  -- Scroll to first error section, or bottom
  local target_row = #lines
  local sorted_rows = {}
  for row_num in pairs(display.section_map) do
    table.insert(sorted_rows, row_num)
  end
  table.sort(sorted_rows)
  for _, row_num in ipairs(sorted_rows) do
    local si = display.section_map[row_num]
    if parsed.sections[si] and parsed.sections[si].has_errors and not parsed.sections[si].collapsed then
      target_row = row_num
      break
    end
  end
  pcall(vim.api.nvim_win_set_cursor, win, { target_row, 0 })

  return handle
end

--- Close the current log view if open.
function M.close()
  if handle and not handle.closed then
    handle.close()
  end
  handle = nil
end

return M
