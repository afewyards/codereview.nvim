local M = {}

local MIN_HEIGHT = 3
local MAX_HEIGHT = 15
local NS = vim.api.nvim_create_namespace("codereview_inline_float")

--- Build context header lines for the float.
--- @param opts table { action_type?, context_text? }
--- @return string[]
function M.build_context_header(opts)
  if not opts.context_text or opts.context_text == "" then return {} end
  if opts.action_type == "comment" then
    return { "  " .. opts.context_text }
  elseif opts.action_type == "reply" then
    return { "  " .. opts.context_text }
  elseif opts.action_type == "edit" then
    return { "  " .. opts.context_text }
  end
  return {}
end

--- Compute float height clamped to [MIN_HEIGHT, MAX_HEIGHT].
--- @param content_lines number
--- @param header_lines number
--- @return number
function M.compute_height(content_lines, header_lines)
  local h = content_lines + header_lines
  return math.max(MIN_HEIGHT, math.min(MAX_HEIGHT, h))
end

--- Create virt_lines extmark to reserve space in the diff buffer.
--- @param diff_buf number
--- @param anchor_line number  0-indexed line
--- @param line_count number
--- @param above? boolean  use virt_lines_above (for placing after existing virt_lines)
--- @return number extmark_id
function M.reserve_space(diff_buf, anchor_line, line_count, above)
  local virt = {}
  for _ = 1, line_count do
    table.insert(virt, { { "", "" } })
  end
  return vim.api.nvim_buf_set_extmark(diff_buf, NS, anchor_line, 0, {
    virt_lines = virt,
    virt_lines_above = above or false,
  })
end

--- Update the extmark to match new height.
--- @param diff_buf number
--- @param extmark_id number
--- @param anchor_line number  0-indexed
--- @param line_count number
--- @param above? boolean  use virt_lines_above
function M.update_space(diff_buf, extmark_id, anchor_line, line_count, above)
  local virt = {}
  for _ = 1, line_count do
    table.insert(virt, { { "", "" } })
  end
  vim.api.nvim_buf_set_extmark(diff_buf, NS, anchor_line, 0, {
    id = extmark_id,
    virt_lines = virt,
    virt_lines_above = above or false,
  })
end

--- Delete the extmark (removes reserved space).
--- @param diff_buf number
--- @param extmark_id number
function M.clear_space(diff_buf, extmark_id)
  pcall(vim.api.nvim_buf_del_extmark, diff_buf, NS, extmark_id)
end

--- Determine border highlight based on action type.
--- @param action_type string|nil
--- @return string
function M.border_hl(action_type)
  if action_type == "reply" then return "CodeReviewReplyBorder" end
  if action_type == "edit" then return "CodeReviewEditBorder" end
  return "CodeReviewCommentBorder"
end

--- Build rounded border with highlight group as {char, hl} tuples.
--- @param action_type string|nil
--- @return table[]
function M.border(action_type)
  local hl = M.border_hl(action_type)
  return {
    { "╭", hl }, { "─", hl }, { "╮", hl },
    { "│", hl },
    { "╯", hl }, { "─", hl }, { "╰", hl },
    { "│", hl },
  }
end

--- Build styled title as {text, hl} tuples.
--- @param text string
--- @return table[]
function M.title(text)
  return { { " " .. text .. " ", "CodeReviewFloatTitle" } }
end

--- Build styled footer with highlighted keys.
--- @return table[]
function M.footer()
  return {
    { " ", "CodeReviewFloatFooterText" },
    { "<C-CR>", "CodeReviewFloatFooterKey" },
    { " submit  ", "CodeReviewFloatFooterText" },
    { "<C-p>", "CodeReviewFloatFooterKey" },
    { " preview  ", "CodeReviewFloatFooterText" },
    { "q", "CodeReviewFloatFooterKey" },
    { " cancel ", "CodeReviewFloatFooterText" },
  }
end

--- Highlight target lines in the diff buffer while the float is open.
--- @param diff_buf number
--- @param start_line number  1-indexed
--- @param end_line number  1-indexed
--- @return number[] extmark_ids
function M.highlight_lines(diff_buf, start_line, end_line)
  local ids = {}
  for row = start_line - 1, end_line - 1 do
    local id = vim.api.nvim_buf_set_extmark(diff_buf, NS, row, 0, {
      line_hl_group = "CodeReviewCommentContext",
      priority = 4097,
    })
    table.insert(ids, id)
  end
  return ids
end

--- Clear line highlights.
--- @param diff_buf number
--- @param ids number[]
function M.clear_line_hl(diff_buf, ids)
  for _, id in ipairs(ids) do
    pcall(vim.api.nvim_buf_del_extmark, diff_buf, NS, id)
  end
end

--- Apply context header highlights to the buffer.
--- @param buf number
--- @param header_count number
function M.apply_header_hl(buf, header_count)
  for i = 0, header_count - 1 do
    vim.api.nvim_buf_add_highlight(buf, NS, "CodeReviewCommentContext", i, 0, -1)
  end
end

return M
