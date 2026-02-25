local M = {}

function M.parse_hunks(diff_text)
  local hunks = {}
  local current_hunk = nil
  local old_line, new_line

  for line in (diff_text .. "\n"):gmatch("(.-)\n") do
    local os, ns = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if os then
      current_hunk = {
        old_start = tonumber(os),
        new_start = tonumber(ns),
        lines = {},
      }
      old_line = tonumber(os)
      new_line = tonumber(ns)
      table.insert(hunks, current_hunk)
    elseif current_hunk then
      local prefix = line:sub(1, 1)
      local content = line:sub(2)

      if prefix == "-" then
        table.insert(current_hunk.lines, {
          type = "delete",
          text = content,
          old_line = old_line,
          new_line = nil,
        })
        old_line = old_line + 1
      elseif prefix == "+" then
        table.insert(current_hunk.lines, {
          type = "add",
          text = content,
          old_line = nil,
          new_line = new_line,
        })
        new_line = new_line + 1
      elseif prefix == " " or line == "" then
        table.insert(current_hunk.lines, {
          type = "context",
          text = content,
          old_line = old_line,
          new_line = new_line,
        })
        old_line = old_line + 1
        new_line = new_line + 1
      end
    end
  end

  return hunks
end

function M.word_diff(old_text, new_text)
  if not old_text or not new_text then return {} end

  local prefix_len = 0
  local max_prefix = math.min(#old_text, #new_text)
  while prefix_len < max_prefix and old_text:byte(prefix_len + 1) == new_text:byte(prefix_len + 1) do
    prefix_len = prefix_len + 1
  end

  local suffix_len = 0
  local max_suffix = math.min(#old_text - prefix_len, #new_text - prefix_len)
  while suffix_len < max_suffix
    and old_text:byte(#old_text - suffix_len) == new_text:byte(#new_text - suffix_len) do
    suffix_len = suffix_len + 1
  end

  -- If no difference found, return empty array
  local old_end = #old_text - suffix_len
  local new_end = #new_text - suffix_len
  if prefix_len >= old_end and prefix_len >= new_end then
    return {}
  end

  return {
    {
      old_start = prefix_len,
      old_end = old_end,
      new_start = prefix_len,
      new_end = new_end,
    },
  }
end

function M.build_display(hunks, context_lines)
  context_lines = context_lines or 3
  local display = {}

  for hunk_idx, hunk in ipairs(hunks) do
    if hunk_idx > 1 then
      table.insert(display, { type = "hunk_boundary" })
    end

    local change_indices = {}
    for i, line in ipairs(hunk.lines) do
      if line.type ~= "context" then
        table.insert(change_indices, i)
      end
    end

    local visible = {}
    for _, ci in ipairs(change_indices) do
      for i = math.max(1, ci - context_lines), math.min(#hunk.lines, ci + context_lines) do
        visible[i] = true
      end
    end

    local hidden_start = nil
    for i, line in ipairs(hunk.lines) do
      if not visible[i] then
        if not hidden_start then
          hidden_start = i
        end
      else
        if hidden_start then
          local hidden_count = i - hidden_start
          table.insert(display, {
            type = "hidden",
            count = hidden_count,
            expandable = true,
            hunk_idx = hunk_idx,
            start_idx = hidden_start,
            end_idx = i - 1,
          })
          hidden_start = nil
        end
        table.insert(display, vim.tbl_extend("force", line, { hunk_idx = hunk_idx, line_idx = i }))
      end
    end

    if hidden_start then
      local hidden_count = #hunk.lines - hidden_start + 1
      table.insert(display, {
        type = "hidden",
        count = hidden_count,
        expandable = true,
        hunk_idx = hunk_idx,
        start_idx = hidden_start,
        end_idx = #hunk.lines,
      })
    end
  end

  return display
end

return M
