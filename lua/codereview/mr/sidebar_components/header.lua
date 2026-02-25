-- lua/codereview/mr/sidebar_components/header.lua
-- Pure render function for the sidebar header.
-- Returns { lines, highlights, row_map } — no side effects.

local M = {}

local CI_ICONS = {
  success = "●",
  failed  = "✗",
  running = "◐",
  pending = "◐",
}

local CI_HLS = {
  success = "CodeReviewFileAdded",
  failed  = "CodeReviewFileDeleted",
  running = "CodeReviewSpinner",
  pending = "CodeReviewSpinner",
}

--- Render the sidebar MR header.
--- @param review table  review/MR data (id, title, source_branch, target_branch,
---                      pipeline_status, approved_by, approvals_required, merge_status)
--- @param width  integer  sidebar column width (default 30)
--- @return table  { lines: string[], highlights: table[], row_map: table }
function M.render(review, width)
  width = width or 30
  local lines      = {}
  local highlights = {}
  local row_map    = {}

  -- Line 1: #ID title  (title truncated so total fits in width)
  local id_prefix  = string.format("#%d ", review.id or 0)
  local title_max  = math.max(0, width - #id_prefix)
  local title      = (review.title or ""):sub(1, title_max)
  table.insert(lines, id_prefix .. title)

  -- Line 2: source_branch → target_branch
  local src = review.source_branch or ""
  local tgt = review.target_branch or "main"
  table.insert(lines, src .. " → " .. tgt)

  -- Line 3: compact status indicators
  local parts   = {}
  local ci_col  = nil   -- byte-start of CI icon in the assembled line (for highlight)

  -- CI indicator
  local ci_status = review.pipeline_status
  local ci_icon   = CI_ICONS[ci_status]
  if ci_icon then
    ci_col = 0
    table.insert(parts, ci_icon)
  end

  -- Approvals: ✓N/M when required > 0, ✓N when approved > 0
  local approved_by = type(review.approved_by) == "table" and review.approved_by or {}
  local required    = type(review.approvals_required) == "number" and review.approvals_required or 0
  local approved_n  = #approved_by
  if required > 0 then
    table.insert(parts, string.format("✓%d/%d", approved_n, required))
  elseif approved_n > 0 then
    table.insert(parts, string.format("✓%d", approved_n))
  end

  -- Merge conflicts
  local ms = review.merge_status
  if ms == "cannot_be_merged" or ms == "conflict" then
    table.insert(parts, "⚠ Conflicts")
  else
    table.insert(parts, "◯ No conflicts")
  end

  local status_line = table.concat(parts, "  ")
  table.insert(lines, status_line)

  -- Highlight CI icon on row 2 (0-indexed)
  if ci_icon and CI_HLS[ci_status] then
    table.insert(highlights, { 2, 0, #ci_icon, CI_HLS[ci_status] })
  end

  -- Line 4: full-width separator
  table.insert(lines, string.rep("─", width))

  return { lines = lines, highlights = highlights, row_map = row_map }
end

return M
