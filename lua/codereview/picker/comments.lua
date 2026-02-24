local M = {}

local function find_file_idx(files, path)
  for i, f in ipairs(files) do
    if f.new_path == path or f.old_path == path then return i end
  end
  return nil
end

function M.build_entries(discussions, ai_suggestions, files, filter)
  local entries = {}

  for _, disc in ipairs(discussions or {}) do
    local note = disc.notes and disc.notes[1]
    if note and note.position then
      local resolved = disc.resolved
      local include = true
      if filter == "unresolved" and resolved then include = false end
      if filter == "resolved" and not resolved then include = false end

      if include then
        local path = note.position.new_path or note.position.old_path
        local line = note.position.new_line or note.position.old_line
        local author = note.author and note.author.username or "unknown"
        local body_first = (note.body or ""):match("^([^\n]*)")
        local status_tag = resolved and "resolved" or "unresolved"

        table.insert(entries, {
          type = "discussion",
          display = string.format("💬 [%s] %s:%d  @%s: %s", status_tag, path, line or 0, author, body_first),
          ordinal = string.format("%s %s %s %s", path, author, body_first, status_tag),
          discussion = disc,
          file_path = path,
          line = line,
          file_idx = find_file_idx(files, path),
        })
      end
    end
  end

  -- AI suggestions: include if not dismissed; skip in "resolved" filter
  if filter ~= "resolved" then
    for _, s in ipairs(ai_suggestions or {}) do
      if s.status ~= "dismissed" then
        table.insert(entries, {
          type = "ai_suggestion",
          display = string.format("🤖 [%s] %s:%d  %s", s.severity or "info", s.file, s.line or 0, s.comment or ""),
          ordinal = string.format("%s %s %s", s.file, s.severity or "", s.comment or ""),
          suggestion = s,
          file_path = s.file,
          line = s.line,
          file_idx = find_file_idx(files, s.file),
        })
      end
    end
  end

  return entries
end

function M.pick(state, layout)
  local picker = require("codereview.picker")
  local name = picker.detect()
  if not name then
    vim.notify("No picker found. Install telescope.nvim, fzf-lua, or snacks.nvim", vim.log.levels.ERROR)
    return
  end

  local entries = M.build_entries(state.discussions, state.ai_suggestions, state.files or {})
  if #entries == 0 then
    vim.notify("No comments or suggestions in current review", vim.log.levels.INFO)
    return
  end

  local function rebuild(filter)
    return M.build_entries(state.discussions, state.ai_suggestions, state.files or {}, filter)
  end

  local adapter = picker.get_adapter(name)
  adapter.pick_comments(entries, function(entry)
    local diff = require("codereview.mr.diff")
    diff.jump_to_comment(layout, state, entry)
  end, { filter_key = "<C-r>", rebuild = rebuild })
end

return M
