local M = {}
local diff_state = require("codereview.mr.diff_state")
local diff_render = require("codereview.mr.diff_render")
local diff_sidebar = require("codereview.mr.diff_sidebar")
local diff_nav = require("codereview.mr.diff_nav")
local diff_comments = require("codereview.mr.diff_comments")

-- ─── Active state tracking ────────────────────────────────────────────────────

local active_states = {}

function M.get_state(buf)
  return active_states[buf]
end

-- ─── Comment/annotation helpers (delegated to diff_comments) ────────────────

M.build_row_items      = diff_comments.build_row_items
M.cycle_row_selection  = diff_comments.cycle_row_selection
M.create_comment_at_cursor = diff_comments.create_comment_at_cursor
M.create_comment_range     = diff_comments.create_comment_range

-- ─── Render functions (delegated to diff_render) ────────────────────────────

M.format_line_number = diff_render.format_line_number
M.place_comment_signs = diff_render.place_comment_signs
M.place_ai_suggestions = diff_render.place_ai_suggestions
M.place_ai_suggestions_all = diff_render.place_ai_suggestions_all
M.render_file_diff = diff_render.render_file_diff
M.render_all_files = diff_render.render_all_files

-- ─── Sidebar and summary rendering (delegated to diff_sidebar) ───────────────

M.render_sidebar = diff_sidebar.render_sidebar
M.render_summary = diff_sidebar.render_summary

-- ─── Navigation helpers (delegated to diff_nav) ───────────────────────────────

M.jump_to_file           = diff_nav.jump_to_file
M.jump_to_comment        = diff_nav.jump_to_comment
M.ensure_virt_lines_visible = diff_nav.ensure_virt_lines_visible
M.find_anchor            = diff_nav.find_anchor
M.find_row_for_anchor    = diff_nav.find_row_for_anchor
M.get_annotated_rows     = diff_nav.get_annotated_rows

--- Check if a file has any annotations (discussions or AI suggestions) without relying on cache.
--- @param state table
--- @param file_idx number
--- @return boolean
function M.file_has_annotations(state, file_idx)
  return diff_state.file_has_annotations(state, file_idx)
end

-- ─── Keymaps ─────────────────────────────────────────────────────────────────

function M.setup_keymaps(layout, state)
  local diff_keymaps = require("codereview.mr.diff_keymaps")
  diff_keymaps.setup_keymaps(state, layout, active_states)
end

-- ─── Lazy diff loading ──────────────────────────────────────────────────────

function M.load_diffs_into_state(state, files)
  diff_state.load_diffs_into_state(state, files)
end

-- ─── Main entry point ─────────────────────────────────────────────────────────

function M.open(review, discussions)
  local providers = require("codereview.providers")
  local client_mod = require("codereview.api.client")
  local split = require("codereview.ui.split")

  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify(err or "Could not detect platform", vim.log.levels.ERROR)
    return
  end

  local files, fetch_err = provider.get_diffs(client_mod, ctx, review)
  if not files then
    vim.notify(fetch_err or "Failed to fetch diffs", vim.log.levels.ERROR)
    return
  end

  local layout = split.create()

  local state = diff_state.create_state({
    view_mode = "diff",
    review = review,
    provider = provider,
    ctx = ctx,
    files = files,
    layout = layout,
    discussions = discussions,
  })

  M.render_sidebar(layout.sidebar_buf, state)

  -- Fetch current user for note authorship checks (edit/delete guards)
  local user = provider.get_current_user(client_mod, ctx)
  if user then state.current_user = user end

  if #files > 0 then
    if state.scroll_mode then
      local render_result = M.render_all_files(layout.main_buf, files, review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user)
      diff_state.apply_scroll_result(state, render_result)
    else
      local line_data, row_disc, row_ai = M.render_file_diff(layout.main_buf, files[1], review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user)
      diff_state.apply_file_result(state, 1, line_data, row_disc, row_ai)
    end
  else
    vim.bo[layout.main_buf].modifiable = true
    vim.api.nvim_buf_set_lines(layout.main_buf, 0, -1, false, { "No diffs found." })
    vim.bo[layout.main_buf].modifiable = false
  end

  M.setup_keymaps(layout, state)
  vim.api.nvim_set_current_win(layout.main_win)

  -- Check for server-side draft comments
  local drafts_mod = require("codereview.review.drafts")
  drafts_mod.check_and_prompt(provider, client_mod, ctx, review, function(server_drafts)
    if server_drafts then
      local session = require("codereview.review.session")
      session.start()
      for _, d in ipairs(server_drafts) do
        table.insert(state.local_drafts, d)
        table.insert(state.discussions, d)
      end
      -- Re-render to show draft markers
      M.render_sidebar(layout.sidebar_buf, state)
      if state.scroll_mode then
        local render_result = M.render_all_files(layout.main_buf, state.files, review, state.discussions, state.context, state.file_contexts, state.ai_suggestions, state.row_selection, state.current_user)
        diff_state.apply_scroll_result(state, render_result)
      else
        M.render_file_diff(layout.main_buf, state.files[state.current_file], review, state.discussions, state.context, state.ai_suggestions, state.row_selection, state.current_user)
      end
    end
  end)
end

return M
