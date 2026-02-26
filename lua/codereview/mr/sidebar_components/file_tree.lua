-- lua/codereview/mr/sidebar_components/file_tree.lua
-- File tree component for the diff sidebar.
-- Renders directory groups and file entries with review status icons and comment counts.

local M = {}

local diff_render = require("codereview.mr.diff_render")
local discussion_matches_file = diff_render.discussion_matches_file

-- ─── Count helpers ─────────────────────────────────────────────────────────

local function count_file_comments(file, discussions)
  local n = 0
  for _, disc in ipairs(discussions or {}) do
    if discussion_matches_file(disc, file) then n = n + 1 end
  end
  return n
end

local function count_file_unresolved(file, discussions)
  local n = 0
  for _, disc in ipairs(discussions or {}) do
    if discussion_matches_file(disc, file) and not disc.local_draft and not disc.resolved then
      n = n + 1
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

-- ─── Review status icons ───────────────────────────────────────────────────

local ICON_UNVISITED = "○"
local ICON_PARTIAL   = "◑"
local ICON_REVIEWED  = "●"

local function get_review_icon(path, state)
  local info = state.file_review_status and state.file_review_status[path]
  local status = info and info.status
  if status == "reviewed" then
    return ICON_REVIEWED
  elseif status == "partial" then
    return ICON_PARTIAL
  else
    return ICON_UNVISITED
  end
end

-- ─── Internal file entry renderer ─────────────────────────────────────────

local function render_file_entry(state, files, entry, lines, row_map, max_name_base)
  local file = files[entry.idx]
  local path = entry.path

  local ccount = count_file_comments(file, state.discussions)
  local cstr = ccount > 0 and (" " .. ccount) or ""
  local ucount = count_file_unresolved(file, state.discussions)
  local ustr = ucount > 0 and (" ⚠" .. ucount) or ""
  local aicount = count_file_ai(file, state.ai_suggestions)
  local aistr = aicount > 0 and (" ✨" .. aicount) or ""

  local review_icon
  if state.view_mode == "diff" and entry.idx == state.current_file then
    review_icon = "▸"
  else
    review_icon = get_review_icon(path, state)
  end

  local name = entry.name
  local max_name = max_name_base - #cstr - #ustr - #aistr
  if #name > max_name then name = ".." .. name:sub(-(max_name - 2)) end

  table.insert(lines, string.format("  %s %s%s%s%s", review_icon, name, cstr, ustr, aistr))
  local review_status = (state.file_review_status
    and state.file_review_status[path]
    and state.file_review_status[path].status)
    or "unvisited"
  row_map[#lines] = { type = "file", idx = entry.idx, path = path, review_status = review_status }
end

-- ─── Public render ─────────────────────────────────────────────────────────

--- Append directory + file rows to lines and record row_map entries.
--- @param state table  diff viewer state
--- @param lines table  mutable lines array
--- @param row_map table  mutable row_map (1-indexed)
function M.render(state, lines, row_map)
  local files = state.files or {}

  -- Build directory grouping (preserving original order)
  local dirs_order = {}
  local dirs = {}
  local root_files = {}

  for i, file in ipairs(files) do
    local path = file.new_path or file.old_path or "unknown"
    local dir = vim.fn.fnamemodify(path, ":h")
    local name = vim.fn.fnamemodify(path, ":t")
    if dir == "." or dir == "" then
      table.insert(root_files, { idx = i, name = name, path = path })
    else
      if not dirs[dir] then
        dirs[dir] = {}
        table.insert(dirs_order, dir)
      end
      table.insert(dirs[dir], { idx = i, name = name, path = path })
    end
  end

  -- Render directories
  for _, dir in ipairs(dirs_order) do
    local collapsed = state.collapsed_dirs and state.collapsed_dirs[dir]
    local icon = collapsed and "▸" or "▾"
    local dir_display = dir
    if #dir_display > 24 then
      dir_display = ".." .. dir_display:sub(-22)
    end
    table.insert(lines, string.format("%s %s/", icon, dir_display))
    row_map[#lines] = { type = "dir", path = dir }

    if not collapsed then
      for _, entry in ipairs(dirs[dir]) do
        render_file_entry(state, files, entry, lines, row_map, 22)
      end
    end
  end

  -- Root-level files
  for _, entry in ipairs(root_files) do
    render_file_entry(state, files, entry, lines, row_map, 24)
  end
end

return M
