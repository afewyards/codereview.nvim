-- lua/codereview/mr/diff_state.lua
-- State factory and mutation helpers for the diff viewer.
-- Single source of truth for the 22+ field state object.

local M = {}

--- Create a new diff viewer state table.
--- @param opts table? Optional overrides:
---   - review table
---   - provider table
---   - ctx table
---   - files table
---   - discussions table
---   - layout table
---   - view_mode string  ("diff"|"summary")
---   - entry table      (detail.lua passes the raw MR list entry)
--- @return table state
function M.create_state(opts)
  opts = opts or {}
  local config = require("codereview.config")
  local cfg = config.get()

  local files = opts.files or {}

  return {
    view_mode = opts.view_mode or "diff",
    review = opts.review,
    provider = opts.provider,
    ctx = opts.ctx,
    entry = opts.entry,
    files = files,
    current_file = 1,
    layout = opts.layout,
    discussions = opts.discussions or {},
    line_data_cache = {},
    row_disc_cache = {},
    sidebar_row_map = {},
    collapsed_dirs = {},
    context = cfg.diff.context,
    scroll_mode = #files <= cfg.diff.scroll_threshold,
    file_sections = {},
    scroll_line_data = {},
    scroll_row_disc = {},
    file_contexts = {},
    ai_suggestions = nil,
    ai_summary_pending = false,
    ai_summary_callbacks = {},
    row_ai_cache = {},
    scroll_row_ai = {},
    local_drafts = {},
    summary_row_map = {},
    row_selection = {},
    current_user = nil,
    git_diff_cache = {},
    file_review_status = {},
  }
end

--- Apply the result table from render_all_files() into state.
--- Replaces the repeated 4-line unpacking pattern.
--- @param state table
--- @param result table  { file_sections, line_data, row_discussions, row_ai }
function M.apply_scroll_result(state, result)
  state.file_sections = result.file_sections
  state.scroll_line_data = result.line_data
  state.scroll_row_disc = result.row_discussions
  state.scroll_row_ai = result.row_ai
end

--- Apply per-file render results into the state caches.
--- Replaces the repeated 3-line cache assignment pattern.
--- @param state table
--- @param idx number file index
--- @param ld table line_data
--- @param rd table row_disc
--- @param ra table row_ai
function M.apply_file_result(state, idx, ld, rd, ra)
  state.line_data_cache[idx] = ld
  state.row_disc_cache[idx] = rd
  state.row_ai_cache[idx] = ra
end

--- Check if a file has any annotations (discussions or AI suggestions) without
--- relying on the render cache.
--- @param state table
--- @param file_idx number
--- @return boolean
function M.file_has_annotations(state, file_idx)
  local files = state.files or {}
  local file = files[file_idx]
  if not file then return false end

  -- Require diff here to avoid circular dependency: diff requires diff_state,
  -- but we only need the private discussion_matches_file logic.
  -- We replicate the simple path-match check inline to stay dependency-free.
  for _, disc in ipairs(state.discussions or {}) do
    local note = disc.notes and disc.notes[1]
    if note and note.position then
      local pos = note.position
      local path = pos.new_path or pos.old_path
      if path == file.new_path or path == file.old_path then
        return true
      end
      -- Also check change_position (outdated GitLab comments)
      if note.change_position then
        local cp = note.change_position
        local cp_path = cp.new_path or cp.old_path
        if cp_path == file.new_path or cp_path == file.old_path then
          return true
        end
      end
    end
  end
  for _, sug in ipairs(state.ai_suggestions or {}) do
    if sug.file_path == file.new_path or sug.file_path == file.old_path then
      return true
    end
  end
  return false
end

--- Clear git diff cache entries, optionally scoped to a path prefix.
--- @param state table
--- @param path string? If provided, only entries whose keys start with this path are removed.
function M.clear_diff_cache(state, path)
  if not path then
    state.git_diff_cache = {}
    return
  end
  -- Escape special Lua pattern characters (vim.pesc unavailable in unit tests)
  local escaped = path:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1")
  for key in pairs(state.git_diff_cache) do
    if key:match("^" .. escaped) then
      state.git_diff_cache[key] = nil
    end
  end
end

--- Populate files into state when not yet loaded (lazy-load helper).
--- Sets scroll_mode from config threshold and initialises cache tables.
--- @param state table
--- @param files table
function M.load_diffs_into_state(state, files)
  if state.files then return end
  local config = require("codereview.config")
  local cfg = config.get()
  state.files = files
  state.scroll_mode = #files <= cfg.diff.scroll_threshold
  state.line_data_cache = state.line_data_cache or {}
  state.row_disc_cache = state.row_disc_cache or {}
  state.file_sections = state.file_sections or {}
  state.scroll_line_data = state.scroll_line_data or {}
  state.scroll_row_disc = state.scroll_row_disc or {}
  state.file_contexts = state.file_contexts or {}
  state.row_ai_cache = state.row_ai_cache or {}
  state.scroll_row_ai = state.scroll_row_ai or {}
  state.local_drafts = state.local_drafts or {}
  state.row_selection = state.row_selection or {}
  state.current_file = 1
end

return M
