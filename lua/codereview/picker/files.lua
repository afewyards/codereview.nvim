local M = {}

local function count_file_comments(file, discussions)
  local n = 0
  for _, disc in ipairs(discussions or {}) do
    local note = disc.notes and disc.notes[1]
    if note and note.position then
      local path = note.position.new_path or note.position.old_path
      if path == file.new_path or path == file.old_path then
        n = n + 1
      end
    end
  end
  return n
end

local function count_file_unresolved(file, discussions)
  local n = 0
  for _, disc in ipairs(discussions or {}) do
    if not disc.local_draft and not disc.resolved then
      local note = disc.notes and disc.notes[1]
      if note and note.position then
        local path = note.position.new_path or note.position.old_path
        if path == file.new_path or path == file.old_path then
          n = n + 1
        end
      end
    end
  end
  return n
end

local function count_file_ai(file, suggestions)
  local n = 0
  local path = file.new_path or file.old_path
  for _, s in ipairs(suggestions or {}) do
    if s.file == path and s.status ~= "dismissed" then n = n + 1 end
  end
  return n
end

function M.build_entries(files, discussions, ai_suggestions)
  local entries = {}
  for idx, file in ipairs(files) do
    local path = file.new_path or file.old_path
    local cc = count_file_comments(file, discussions)
    local uc = count_file_unresolved(file, discussions)
    local ac = count_file_ai(file, ai_suggestions)

    local parts = { path }
    if cc > 0 then table.insert(parts, "[" .. cc .. "]") end
    if uc > 0 then table.insert(parts, "⚠" .. uc) end
    if ac > 0 then table.insert(parts, "🤖" .. ac) end

    table.insert(entries, {
      display = table.concat(parts, "  "),
      ordinal = path,
      file_path = path,
      file_idx = idx,
      comment_count = cc,
      unresolved_count = uc,
      ai_count = ac,
    })
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

  local entries = M.build_entries(state.files or {}, state.discussions, state.ai_suggestions)
  if #entries == 0 then
    vim.notify("No files in current review", vim.log.levels.INFO)
    return
  end

  local adapter = picker.get_adapter(name)
  adapter.pick_files(entries, function(entry)
    local diff = require("codereview.mr.diff")
    diff.jump_to_file(layout, state, entry.file_idx)
  end)
end

return M
