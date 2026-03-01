-- lua/codereview/mr/commit_filter.lua
-- Manages applying/clearing commit filters on diff state.

local M = {}

local function clear_caches(state)
  state.line_data_cache = {}
  state.row_disc_cache = {}
  state.git_diff_cache = {}
  state.scroll_line_data = {}
  state.scroll_row_disc = {}
  state.row_ai_cache = {}
  state.scroll_row_ai = {}
  state.file_review_status = {}
  state.file_sections = {}
end

--- Check if a discussion note matches the given commit filter (by to_sha).
--- Supports both GitLab (head_sha) and GitHub (commit_sha) position fields.
--- @param disc table
--- @param filter table { from_sha, to_sha }
--- @return boolean
function M.matches_discussion(disc, filter)
  for _, note in ipairs(disc.notes or {}) do
    local pos = note.position
    if pos then
      if pos.head_sha == filter.to_sha or pos.commit_sha == filter.to_sha then
        return true
      end
    end
  end
  return false
end

--- Apply a commit filter to state, restricting files and discussions.
--- Backs up originals before filtering so clear() can restore them.
--- @param state table diff viewer state
--- @param filter table { from_sha, to_sha, label, changed_paths }
function M.apply(state, filter)
  if not state.original_files then
    state.original_files = state.files
  end
  if not state.original_discussions then
    state.original_discussions = state.discussions
  end

  state.commit_filter = { from_sha = filter.from_sha, to_sha = filter.to_sha, label = filter.label }

  local path_set = {}
  for _, p in ipairs(filter.changed_paths or {}) do
    path_set[p] = true
  end

  local filtered_files = {}
  for _, f in ipairs(state.original_files) do
    if path_set[f.new_path] then
      table.insert(filtered_files, f)
    end
  end
  state.files = filtered_files

  local filtered_discussions = {}
  for _, d in ipairs(state.original_discussions) do
    if M.matches_discussion(d, state.commit_filter) then
      table.insert(filtered_discussions, d)
    end
  end
  state.discussions = filtered_discussions

  state.current_file = 1
  clear_caches(state)
end

--- Clear the active commit filter, restoring original files and discussions.
--- @param state table diff viewer state
function M.clear(state)
  if state.original_files then
    state.files = state.original_files
    state.original_files = nil
  end
  if state.original_discussions then
    state.discussions = state.original_discussions
    state.original_discussions = nil
  end
  state.commit_filter = nil
  state.current_file = 1
  clear_caches(state)
end

--- Return true if a commit filter is currently active.
--- @param state table
--- @return boolean
function M.is_active(state)
  return state.commit_filter ~= nil
end

--- Get the list of file paths changed between two SHAs via git diff.
--- @param from_sha string
--- @param to_sha string
--- @return string[]
function M.get_changed_paths(from_sha, to_sha)
  local result = vim.fn.system({ "git", "diff", "--name-only", from_sha .. ".." .. to_sha })
  if vim.v.shell_error ~= 0 then return {} end
  local paths = {}
  for path in result:gmatch("[^\n]+") do
    if path ~= "" then
      table.insert(paths, path)
    end
  end
  return paths
end

return M
