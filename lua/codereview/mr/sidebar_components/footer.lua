-- lua/codereview/mr/sidebar_components/footer.lua
-- Three-line footer: separator, progress bar, right-aligned help hint.

local M = {}

--- Build footer lines for the sidebar.
--- @param state table  diff viewer state (files, file_review_status, discussions)
--- @param width integer  display width for separator and right-align
--- @return string[] lines
--- @return table[] highlights  Array of {row:integer (1-indexed), line_hl:string}
function M.build(state, width)
  width = width or 30

  -- Count reviewed files
  local total = #(state.files or {})
  local reviewed = 0
  for _, file in ipairs(state.files or {}) do
    local path = file.new_path or file.old_path
    local frs = path and state.file_review_status and state.file_review_status[path]
    if frs and frs.status == "reviewed" then
      reviewed = reviewed + 1
    end
  end

  -- Count unresolved discussions (not draft, not resolved)
  local unresolved = 0
  for _, disc in ipairs(state.discussions or {}) do
    if not disc.local_draft and not disc.resolved then
      unresolved = unresolved + 1
    end
  end

  local lines = {}
  local highlights = {}

  -- Line 1: full-width separator
  lines[1] = string.rep("─", width)
  highlights[1] = { row = 1, line_hl = "CodeReviewProgressDim" }

  -- Line 2: progress counts
  lines[2] = string.format("%d/%d reviewed  •  %d unresolved", reviewed, total, unresolved)
  highlights[2] = { row = 2, line_hl = "CodeReviewProgressDim" }

  -- Line 3: right-aligned help hint
  local hint = "? help"
  local pad = math.max(0, width - #hint)
  lines[3] = string.rep(" ", pad) .. hint

  return lines, highlights
end

return M
