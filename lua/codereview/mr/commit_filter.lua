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

--- Build a map from commit SHA to the version head_commit_sha(s) that contain it.
--- Commits list is newest-first. Versions are sorted by created_at ascending.
--- @param commits table[] Array of { sha, ... } (newest first)
--- @param versions table[] Array of { head_commit_sha, created_at }
--- @return table<string, string[]> commit_sha -> list of version head SHAs
function M.build_version_map(commits, versions)
  if #commits == 0 or #versions == 0 then
    return {}
  end

  -- Sort versions by created_at ascending (oldest first)
  local sorted_versions = {}
  for _, v in ipairs(versions) do
    table.insert(sorted_versions, v)
  end
  table.sort(sorted_versions, function(a, b)
    return (a.created_at or "") < (b.created_at or "")
  end)

  -- Reverse commits to oldest-first
  local ordered = {}
  for i = #commits, 1, -1 do
    table.insert(ordered, commits[i].sha)
  end

  -- Build commit_index for O(1) lookup
  local commit_index = {}
  for i, sha in ipairs(ordered) do
    commit_index[sha] = i
  end

  -- Walk versions; each version "owns" commits from prev boundary+1 to its head
  local map = {}
  local prev_idx = 0
  for _, v in ipairs(sorted_versions) do
    local v_idx = commit_index[v.head_commit_sha]
    if v_idx then
      for i = prev_idx + 1, v_idx do
        map[ordered[i]] = map[ordered[i]] or {}
        table.insert(map[ordered[i]], v.head_commit_sha)
      end
      prev_idx = v_idx
    end
  end

  return map
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
  local matched_paths = {}
  for _, f in ipairs(state.original_files) do
    if path_set[f.new_path] or path_set[f.old_path] then
      table.insert(filtered_files, f)
      if f.new_path then
        matched_paths[f.new_path] = true
      end
      if f.old_path then
        matched_paths[f.old_path] = true
      end
    end
  end
  -- Add files not in the MR-level diff (e.g. changed then reverted later).
  -- Prefer commit_files (API data with real diffs) when available.
  for _, f in ipairs(filter.commit_files or {}) do
    if not matched_paths[f.new_path or ""] and not matched_paths[f.old_path or ""] then
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
  if vim.v.shell_error ~= 0 then
    return {}
  end
  local paths = {}
  for path in result:gmatch("[^\n]+") do
    if path ~= "" then
      table.insert(paths, path)
    end
  end
  return paths
end

--- Handle a commit picker/sidebar entry selection.
--- Applies or clears the commit filter, re-renders sidebar and diff.
--- @param state table diff viewer state
--- @param layout table { sidebar_buf, main_buf, ... }
--- @param entry table picker entry { type, sha, title, from_sha, ... }
function M.select(state, layout, entry)
  local diff = require("codereview.mr.diff")
  local diff_render = require("codereview.mr.diff_render")
  local diff_state = require("codereview.mr.diff_state")

  local function render_current_file()
    if state.scroll_mode then
      local result = diff_render.render_all_files(
        layout.main_buf,
        state.files,
        state.review,
        state.discussions,
        state.context,
        state.file_contexts,
        state.ai_suggestions,
        state.row_selection,
        state.current_user,
        state.editing_note,
        state.git_diff_cache,
        state.commit_filter
      )
      diff_state.apply_scroll_result(state, result)
    else
      local file = state.files and state.files[state.current_file]
      if file then
        local ld, rd, ra = diff_render.render_file_diff(
          layout.main_buf,
          file,
          state.review,
          state.discussions,
          state.context,
          state.ai_suggestions,
          state.row_selection,
          state.current_user,
          state.editing_note,
          state.git_diff_cache,
          state.commit_filter
        )
        diff_state.apply_file_result(state, state.current_file, ld, rd, ra)
      end
    end
  end

  if entry.type == "all" then
    if M.is_active(state) then
      M.clear(state)
      diff.render_sidebar(layout.sidebar_buf, state)
      if state.view_mode == "diff" then
        render_current_file()
      end
    end
  elseif entry.type == "since_last_review" then
    diff_render.ensure_git_objects(entry.from_sha, state.review.head_sha)
    local paths = M.get_changed_paths(entry.from_sha, state.review.head_sha)
    M.apply(state, {
      from_sha = entry.from_sha,
      to_sha = state.review.head_sha,
      label = "Since last review",
      changed_paths = paths,
    })
    state.view_mode = "diff"
    diff.render_sidebar(layout.sidebar_buf, state)
    render_current_file()
    if layout.main_win and vim.api.nvim_win_is_valid(layout.main_win) then
      vim.api.nvim_set_current_win(layout.main_win)
    end
  elseif entry.type == "commit" then
    -- Fetch per-commit file diffs from the provider API (authoritative source).
    local client_mod = require("codereview.api.client")
    local commit_diffs = state.provider.get_commit_diffs(client_mod, state.ctx, entry.sha) or {}
    local paths = {}
    for _, f in ipairs(commit_diffs) do
      if f.new_path and f.new_path ~= "" then
        paths[#paths + 1] = f.new_path
      end
      if f.old_path and f.old_path ~= "" and f.old_path ~= f.new_path then
        paths[#paths + 1] = f.old_path
      end
    end
    -- Parent SHA still needed for commit_filter.from_sha (diff rendering context).
    diff_render.ensure_git_objects(state.review.base_sha, entry.sha)
    local parent_result = vim.fn.system({ "git", "rev-parse", entry.sha .. "~1" })
    local parent_sha = vim.v.shell_error == 0 and parent_result:gsub("%s+", "") or state.review.base_sha
    M.apply(state, {
      from_sha = parent_sha,
      to_sha = entry.sha,
      label = entry.title or entry.sha:sub(1, 8),
      changed_paths = paths,
      commit_files = commit_diffs,
    })
    state.view_mode = "diff"
    diff.render_sidebar(layout.sidebar_buf, state)
    render_current_file()
    if layout.main_win and vim.api.nvim_win_is_valid(layout.main_win) then
      vim.api.nvim_set_current_win(layout.main_win)
    end
  end
end

return M
