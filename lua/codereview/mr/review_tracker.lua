-- lua/codereview/mr/review_tracker.lua
-- Hunk-based file review tracking.
-- Tracks which diff hunks have been scrolled past and computes per-file
-- review status (unvisited / partial / reviewed) for the sidebar.

local M = {}

--- Build initial tracking state for a file.
--- Scans line_data for hunk boundaries (transitions in item.hunk_idx).
--- In scroll mode, pass file_idx to filter lines belonging to this file.
--- @param path string       file path (used as key in state.file_review_status)
--- @param line_data table   list of line_data entries from render output
--- @param file_idx integer? when non-nil, only count lines where data.file_idx == file_idx
--- @return table  { path, hunks_total, hunks_seen, hunk_rows, seen, status }
function M.init_file(path, line_data, file_idx)
  local hunk_rows = {}   -- row (1-based) -> hunk_idx of hunk that starts at that row
  local hunks_total = 0
  local last_hunk_idx = nil

  for i, data in ipairs(line_data) do
    if file_idx and data.file_idx and data.file_idx ~= file_idx then
      -- scroll mode: skip lines that belong to a different file
    elseif data.item and data.item.hunk_idx then
      if data.item.hunk_idx ~= last_hunk_idx then
        last_hunk_idx = data.item.hunk_idx
        hunks_total = hunks_total + 1
        hunk_rows[i] = data.item.hunk_idx
      end
    end
  end

  return {
    path = path,
    hunks_total = hunks_total,
    hunks_seen = 0,
    hunk_rows = hunk_rows,
    seen = {},
    status = "unvisited",
  }
end

--- Mark all hunks whose start rows fall within [top_row, bot_row] as seen.
--- Mutates file_status in-place; updates hunks_seen and status.
--- @param file_status table  value from state.file_review_status[path]
--- @param top_row integer    first visible buffer row (1-based)
--- @param bot_row integer    last visible buffer row (1-based)
--- @return boolean  true if status changed (triggers sidebar re-render)
function M.mark_visible(file_status, top_row, bot_row)
  local changed = false

  for row, hunk_idx in pairs(file_status.hunk_rows) do
    if row >= top_row and row <= bot_row then
      if not file_status.seen[hunk_idx] then
        file_status.seen[hunk_idx] = true
        file_status.hunks_seen = file_status.hunks_seen + 1
        changed = true
      end
    end
  end

  if changed then
    if file_status.hunks_total == 0 or file_status.hunks_seen >= file_status.hunks_total then
      file_status.status = "reviewed"
    else
      file_status.status = "partial"
    end
  end

  return changed
end

return M
