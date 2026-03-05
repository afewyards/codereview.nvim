-- lua/codereview/mr/winbar.lua
-- Manages the main pane winbar for commit filter display.

local M = {}

--- Set the winbar on the main pane to show the active commit.
--- @param win integer  main window handle
--- @param sha string   full commit SHA
--- @param title string commit title
function M.set_commit(win, sha, title)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local short_sha = sha:sub(1, 7)
  -- %#HlGroup# syntax: dim SHA, normal title
  vim.wo[win].winbar = " %#CodeReviewWinbarIcon#●%* %#CodeReviewWinbarSha#" .. short_sha .. "%* " .. title
end

--- Clear the winbar on the main pane.
--- @param win integer  main window handle
function M.clear(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.wo[win].winbar = ""
end

return M
