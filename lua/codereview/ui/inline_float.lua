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
--- @return number extmark_id
function M.reserve_space(diff_buf, anchor_line, line_count)
  local virt = {}
  for _ = 1, line_count do
    table.insert(virt, { { "", "" } })
  end
  return vim.api.nvim_buf_set_extmark(diff_buf, NS, anchor_line, 0, {
    virt_lines = virt,
  })
end

--- Update the extmark to match new height.
--- @param diff_buf number
--- @param extmark_id number
--- @param anchor_line number  0-indexed
--- @param line_count number
function M.update_space(diff_buf, extmark_id, anchor_line, line_count)
  local virt = {}
  for _ = 1, line_count do
    table.insert(virt, { { "", "" } })
  end
  vim.api.nvim_buf_set_extmark(diff_buf, NS, anchor_line, 0, {
    id = extmark_id,
    virt_lines = virt,
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

--- Apply context header highlights to the buffer.
--- @param buf number
--- @param header_count number
function M.apply_header_hl(buf, header_count)
  for i = 0, header_count - 1 do
    vim.api.nvim_buf_add_highlight(buf, NS, "CodeReviewCommentContext", i, 0, -1)
  end
end

return M
