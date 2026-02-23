-- lua/codereview/review/triage.lua
local split = require("codereview.ui.split")
local diff_mod = require("codereview.mr.diff")
local submit_mod = require("codereview.review.submit")
local M = {}

local DRAFT_NS = vim.api.nvim_create_namespace("codereview_ai_draft")

local STATUS_ICONS = { accepted = "+", pending = "o", deleted = "x", edited = "~" }

function M.open(review, diffs, discussions, suggestions)
  if #suggestions == 0 then
    vim.notify("AI review found no issues!", vim.log.levels.INFO)
    return
  end

  local layout = split.create({ sidebar_width = 30 })

  local state = {
    layout = layout,
    review = review,
    diffs = diffs,
    discussions = discussions,
    suggestions = suggestions,
    current_idx = 1,
    line_data = nil,
  }

  M.render(state)
  M.setup_keymaps(state)
  return state
end

function M.build_sidebar_lines(suggestions, current_idx)
  local lines = {}
  local accepted = 0
  for _, s in ipairs(suggestions) do
    if s.status == "accepted" or s.status == "edited" then accepted = accepted + 1 end
  end

  table.insert(lines, string.format("AI Review: %d comments", #suggestions))
  table.insert(lines, string.rep("=", 28))
  table.insert(lines, "")

  for i, s in ipairs(suggestions) do
    if s.status == "deleted" then goto continue end
    local icon = STATUS_ICONS[s.status] or "o"
    local pointer = i == current_idx and "> " or "  "
    local short_file = s.file:match("[^/]+$") or s.file
    table.insert(lines, string.format("%s%s %d. %s:%d", pointer, icon, i, short_file, s.line))
    table.insert(lines, string.format("    %s", s.comment:sub(1, 40)))
    if s.status == "pending" then
      table.insert(lines, "    [a]ccept [e]dit [d]el")
    else
      table.insert(lines, string.format("    %s", s.status))
    end
    table.insert(lines, "")
    ::continue::
  end

  table.insert(lines, string.rep("=", 28))
  table.insert(lines, string.format("Reviewed: %d/%d", accepted, #suggestions))
  table.insert(lines, "[A] Accept all  [S] Submit")
  table.insert(lines, "[q] Quit")

  return lines
end

function M.render(state)
  local layout = state.layout

  -- Sidebar
  local sidebar_lines = M.build_sidebar_lines(state.suggestions, state.current_idx)
  vim.bo[layout.sidebar_buf].modifiable = true
  vim.api.nvim_buf_set_lines(layout.sidebar_buf, 0, -1, false, sidebar_lines)
  vim.bo[layout.sidebar_buf].modifiable = false

  -- Main: render diff for current suggestion's file
  local current = state.suggestions[state.current_idx]
  if not current then return end

  for _, file_diff in ipairs(state.diffs) do
    if file_diff.new_path == current.file or file_diff.old_path == current.file then
      state.line_data = diff_mod.render_file_diff(
        layout.main_buf, file_diff, state.review, state.discussions
      )
      M.show_inline_draft(layout.main_buf, state.line_data, current)
      M.scroll_to_line(layout.main_win, state.line_data, current.line)
      break
    end
  end
end

function M.show_inline_draft(buf, line_data, suggestion)
  vim.api.nvim_buf_clear_namespace(buf, DRAFT_NS, 0, -1)

  for i, data in ipairs(line_data) do
    local new_line = data.item and data.item.new_line
    if new_line == suggestion.line then
      local virt_lines = {
        { { string.rep("-", 50), "CodeReviewAIDraftBorder" } },
        { { " AI [" .. suggestion.severity .. "]", "CodeReviewAIDraft" } },
        { { " " .. suggestion.comment, "CodeReviewAIDraft" } },
        { { string.rep("-", 50), "CodeReviewAIDraftBorder" } },
      }
      vim.api.nvim_buf_set_extmark(buf, DRAFT_NS, i - 1, 0, {
        virt_lines = virt_lines,
        virt_lines_above = false,
      })
      break
    end
  end
end

function M.scroll_to_line(win, line_data, target_line)
  for i, data in ipairs(line_data) do
    local new_line = data.item and data.item.new_line
    if new_line == target_line then
      pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
      vim.cmd("normal! zz")
      return
    end
  end
end

function M.navigate(state, direction)
  local new_idx = state.current_idx
  repeat
    new_idx = new_idx + direction
  until new_idx < 1 or new_idx > #state.suggestions or state.suggestions[new_idx].status ~= "deleted"

  if new_idx >= 1 and new_idx <= #state.suggestions then
    state.current_idx = new_idx
    M.render(state)
  end
end

function M.accept(state)
  state.suggestions[state.current_idx].status = "accepted"
  M.navigate(state, 1)
end

function M.delete_suggestion(state)
  state.suggestions[state.current_idx].status = "deleted"
  M.navigate(state, 1)
end

function M.edit(state)
  local ifloat = require("codereview.ui.inline_float")
  local current = state.suggestions[state.current_idx]
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(current.comment, "\n"))
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(60, vim.o.columns - 20)
  local height = math.max(5, #vim.split(current.comment, "\n") + 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    width = width,
    height = height,
    col = 2,
    row = 1,
    style = "minimal",
    border = ifloat.border("edit"),
    title = " Edit Comment ",
    title_pos = "center",
  })

  vim.keymap.set("n", "<CR>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    current.comment = table.concat(lines, "\n")
    current.status = "edited"
    vim.api.nvim_win_close(win, true)
    M.navigate(state, 1)
  end, { buffer = buf })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
end

function M.accept_all(state)
  for _, s in ipairs(state.suggestions) do
    if s.status == "pending" then s.status = "accepted" end
  end
  M.render(state)
end

function M.submit(state)
  submit_mod.submit_review(state.review, state.suggestions)
  split.close(state.layout)
end

function M.setup_keymaps(state)
  local layout = state.layout
  local opts = { nowait = true }

  for _, buf in ipairs({ layout.main_buf, layout.sidebar_buf }) do
    local buf_opts = vim.tbl_extend("force", opts, { buffer = buf })
    vim.keymap.set("n", "a", function() M.accept(state) end, buf_opts)
    vim.keymap.set("n", "d", function() M.delete_suggestion(state) end, buf_opts)
    vim.keymap.set("n", "e", function() M.edit(state) end, buf_opts)
    vim.keymap.set("n", "A", function() M.accept_all(state) end, buf_opts)
    vim.keymap.set("n", "S", function() M.submit(state) end, buf_opts)
    vim.keymap.set("n", "]c", function() M.navigate(state, 1) end, buf_opts)
    vim.keymap.set("n", "[c", function() M.navigate(state, -1) end, buf_opts)
    vim.keymap.set("n", "q", function() split.close(layout) end, buf_opts)
  end
end

return M
