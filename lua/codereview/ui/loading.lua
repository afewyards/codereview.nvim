-- lua/codereview/ui/loading.lua
-- Centered loading float with animated spinner.
local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local INTERVAL_MS = 80

local win_id = nil
local buf_id = nil
local timer_id = nil
local frame_idx = 1

function M.open(label)
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    return
  end

  label = label or "Loading…"
  buf_id = vim.api.nvim_create_buf(false, true)
  vim.bo[buf_id].bufhidden = "wipe"

  local text = " " .. FRAMES[1] .. " " .. label .. " "
  local width = vim.fn.strdisplaywidth(text) + 2
  local editor_w = vim.o.columns
  local editor_h = vim.o.lines

  win_id = vim.api.nvim_open_win(buf_id, false, {
    relative = "editor",
    row = math.floor(editor_h / 2) - 1,
    col = math.floor((editor_w - width) / 2),
    width = width,
    height = 1,
    style = "minimal",
    focusable = false,
    zindex = 50,
    border = "rounded",
  })

  vim.api.nvim_set_option_value("winblend", 0, { win = win_id })

  frame_idx = 1
  local function update()
    if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
      M.close()
      return
    end
    local line = " " .. FRAMES[frame_idx] .. " " .. label .. " "
    vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, { line })
    frame_idx = frame_idx % #FRAMES + 1
  end

  update()
  timer_id = vim.fn.timer_start(INTERVAL_MS, function()
    vim.schedule(update)
  end, { ["repeat"] = -1 })
end

function M.close()
  if timer_id then
    vim.fn.timer_stop(timer_id)
    timer_id = nil
  end
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_win_close(win_id, true)
  end
  win_id = nil
  buf_id = nil
  frame_idx = 1
end

return M
