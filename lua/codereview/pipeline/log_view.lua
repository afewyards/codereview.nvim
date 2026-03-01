-- lua/codereview/pipeline/log_view.lua
-- Secondary float for displaying job trace logs with ANSI rendering.
local M = {}

local ansi = require("codereview.pipeline.ansi")

local ns = vim.api.nvim_create_namespace("codereview_pipeline_log")

local handle = nil

--- Open a log view float for a job trace.
--- @param job table  normalized pipeline job
--- @param trace string  raw job log text
--- @param max_lines number?  truncation limit (default 5000)
--- @return table  handle { buf, win, close, closed }
function M.open(job, trace, max_lines)
  M.close() -- close any existing log view

  max_lines = max_lines or 5000
  local parsed = ansi.parse(trace)
  local lines = parsed.lines

  -- Truncate very long logs
  if #lines > max_lines then
    local truncated = {}
    for i = 1, max_lines do truncated[i] = lines[i] end
    table.insert(truncated, string.format("... truncated (%d lines total)", #lines))
    lines = truncated
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "codereview_pipeline_log"

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Apply ANSI highlights
  for _, hl in ipairs(parsed.highlights) do
    if hl.line <= #lines then
      pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl_group, hl.line - 1, hl.col_start, hl.col_end)
    end
  end

  local width = math.min(120, math.floor(vim.o.columns * 0.8))
  local height = math.min(30, math.floor(vim.o.lines * 0.6))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local title = string.format(" %s — %s ", job.name or "Job", job.status or "")

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = {{ title, "CodeReviewFloatTitle" }},
    title_pos = "center",
    zindex = 60,
  })

  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("number", true, { win = win })

  handle = { buf = buf, win = win, closed = false }

  function handle.close()
    if handle.closed then return end
    handle.closed = true
    pcall(vim.api.nvim_win_close, win, true)
  end

  -- Keymaps
  local opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set("n", "q", handle.close, vim.tbl_extend("force", opts, { desc = "Close log" }))
  vim.keymap.set("n", "<Esc>", handle.close, vim.tbl_extend("force", opts, { desc = "Close log" }))

  -- Auto-close on WinClosed
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() handle.close() end,
  })

  -- Scroll to bottom (latest output)
  pcall(vim.api.nvim_win_set_cursor, win, { #lines, 0 })

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
