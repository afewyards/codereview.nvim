local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local INTERVAL = 80

-- Active spinners keyed by window id
local active = {}

function M.start(win, message)
  if not vim.api.nvim_win_is_valid(win) then return end
  M.stop(win)

  local saved = vim.wo[win].winbar
  local frame_idx = 1

  local timer = vim.uv.new_timer()
  active[win] = { timer = timer, saved_winbar = saved }

  timer:start(0, INTERVAL, vim.schedule_wrap(function()
    if not vim.api.nvim_win_is_valid(win) then
      M.stop(win)
      return
    end
    local icon = FRAMES[frame_idx]
    vim.wo[win].winbar = "%#CodeReviewSpinner# " .. icon .. " " .. message .. " %*"
    frame_idx = frame_idx % #FRAMES + 1
  end))
end

function M.stop(win)
  local entry = active[win]
  if not entry then return end
  entry.timer:stop()
  entry.timer:close()
  if vim.api.nvim_win_is_valid(win) then
    vim.wo[win].winbar = entry.saved_winbar or ""
  end
  active[win] = nil
end

return M
