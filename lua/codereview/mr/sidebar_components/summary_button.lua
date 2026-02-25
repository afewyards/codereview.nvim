-- lua/codereview/mr/sidebar_components/summary_button.lua
-- Summary button component for the diff sidebar.

local M = {}

--- Append the Summary button rows to lines and record the row_map entry.
--- Adds 2 lines: the button line + a blank separator.
--- @param state table  diff viewer state (needs .view_mode)
--- @param lines table  mutable lines array
--- @param row_map table  mutable row_map (1-indexed)
function M.render(state, lines, row_map)
  local indicator = (state.view_mode == "summary") and "▸" or " "
  table.insert(lines, string.format("%s ℹ Summary", indicator))
  row_map[#lines] = { type = "summary" }
  table.insert(lines, "")
end

return M
