local M = {}

--- Build ordered list of selectable items at a row.
--- @param ai_suggestions table[] array of AI suggestions at this row
--- @param discussions table[] array of discussions at this row
--- @return table[] items ordered: AI first, then comment notes
function M.build_row_items(ai_suggestions, discussions)
  local items = {}
  for i = 1, #ai_suggestions do
    table.insert(items, { type = "ai", index = i })
  end
  for _, disc in ipairs(discussions) do
    for ni, note in ipairs(disc.notes or {}) do
      if not note.system then
        table.insert(items, { type = "comment", disc_id = disc.id, note_idx = ni })
      end
    end
  end
  return items
end

--- Cycle through row items.
--- @param items table[] from build_row_items
--- @param current table|nil current selection
--- @param direction number +1 forward, -1 backward
--- @return table|nil next selection
function M.cycle_row_selection(items, current, direction)
  if #items == 0 then return nil end
  if not current then
    return direction > 0 and items[1] or items[#items]
  end
  -- Find current position
  local pos
  for i, item in ipairs(items) do
    if item.type == current.type then
      if item.type == "ai" and item.index == current.index then
        pos = i; break
      elseif item.type == "comment" and item.disc_id == current.disc_id and item.note_idx == current.note_idx then
        pos = i; break
      end
    end
  end
  if not pos then return direction > 0 and items[1] or items[#items] end
  local next_pos = pos + direction
  if next_pos < 1 or next_pos > #items then return nil end
  return items[next_pos]
end

--- Create an inline comment at the current cursor position.
--- @param layout table  diff layout (main_win, main_buf)
--- @param state  table  diff state
--- @param optimistic table|nil  optimistic callbacks {add, remove, mark_failed, refresh}
function M.create_comment_at_cursor(layout, state, optimistic)
  local line_data = state.line_data_cache[state.current_file]
  if not line_data then return end
  local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
  local row = cursor[1]
  local data = line_data[row]
  if not data or not data.item then
    vim.notify("No diff line at cursor", vim.log.levels.WARN)
    return
  end
  if data.type == "context" then
    vim.notify("Cannot comment on unchanged lines", vim.log.levels.WARN)
    return
  end
  local file = state.files[state.current_file]
  local line_text = vim.api.nvim_buf_get_lines(
    vim.api.nvim_win_get_buf(layout.main_win), row - 1, row, false
  )[1] or ""
  local built_opt = optimistic and {
    add = optimistic.add(file.old_path, file.new_path, data.item.old_line, data.item.new_line),
    remove = optimistic.remove,
    mark_failed = optimistic.mark_failed,
    refresh = optimistic.refresh,
  } or nil
  local comment = require("codereview.mr.comment")
  comment.create_inline(
    state.review,
    file.old_path,
    file.new_path,
    data.item.old_line,
    data.item.new_line,
    built_opt,
    { anchor_line = row, win_id = layout.main_win, action_type = "comment", context_text = line_text }
  )
end

--- Create an inline range comment over the current visual selection.
--- @param layout table  diff layout (main_win, main_buf)
--- @param state  table  diff state
--- @param optimistic table|nil  optimistic callbacks {add, remove, mark_failed, refresh}
function M.create_comment_range(layout, state, optimistic)
  local line_data = state.line_data_cache[state.current_file]
  if not line_data then return end
  -- Get visual selection range
  local s, e = vim.fn.line("v"), vim.fn.line(".")
  if s > e then s, e = e, s end
  local start_data = line_data[s]
  local end_data = line_data[e]
  if not start_data or not end_data then
    vim.notify("Invalid selection range", vim.log.levels.WARN)
    return
  end
  if start_data.type == "context" or end_data.type == "context" then
    vim.notify("Cannot comment on unchanged lines", vim.log.levels.WARN)
    return
  end
  local file = state.files[state.current_file]
  local line_text = vim.api.nvim_buf_get_lines(
    vim.api.nvim_win_get_buf(layout.main_win), e - 1, e, false
  )[1] or ""
  local built_opt = optimistic and {
    add = optimistic.add(file.old_path, file.new_path, end_data.item.old_line, end_data.item.new_line, start_data.item.new_line),
    remove = optimistic.remove,
    mark_failed = optimistic.mark_failed,
    refresh = optimistic.refresh,
  } or nil
  local comment = require("codereview.mr.comment")
  comment.create_inline_range(
    state.review,
    file.old_path,
    file.new_path,
    { old_line = start_data.item.old_line, new_line = start_data.item.new_line },
    { old_line = end_data.item.old_line, new_line = end_data.item.new_line },
    built_opt,
    { anchor_line = e, anchor_start = s, win_id = layout.main_win, action_type = "comment", context_text = line_text }
  )
end

return M
