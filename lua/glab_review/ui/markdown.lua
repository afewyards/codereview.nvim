local M = {}

function M.to_lines(text)
  if not text then return {} end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  -- Remove trailing empty line from our split
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

function M.render_to_buf(buf, text, start_line)
  start_line = start_line or 0
  local lines = M.to_lines(text)
  vim.api.nvim_buf_set_lines(buf, start_line, start_line, false, lines)
  vim.bo[buf].filetype = "markdown"
  return #lines
end

function M.set_buf_markdown(buf)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].syntax = "markdown"
end

return M
