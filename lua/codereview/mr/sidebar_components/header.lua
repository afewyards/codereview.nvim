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
--- @param state_or_review table  either a diff state (with .review) or a review object directly
--- @param width  integer  sidebar column width (default 30)
--- @return table  { lines: string[], highlights: table[], row_map: table }
function M.render(state_or_review, width)
  width = width or 30
  local lines      = {}
  local highlights = {}
  local row_map    = {}

  local review, commit_filter
  if state_or_review.review then
    review = state_or_review.review
    commit_filter = state_or_review.commit_filter
  else
    review = state_or_review
  end

  -- Line 1: #ID title  (title truncated so total fits in width)
  local id_prefix  = string.format("#%d ", review.id or 0)
  local title_max  = math.max(0, width - #id_prefix)
  local title      = (review.title or ""):sub(1, title_max)
  table.insert(lines, id_prefix .. title)

  -- Line 2: source_branch → target_branch
  local src = review.source_branch or ""
  local tgt = review.target_branch or "main"
  table.insert(lines, src .. " → " .. tgt)

  -- Optional commit filter banner (full-width background highlight)
  if commit_filter and commit_filter.label then
    local icon_label = "🔍 " .. commit_filter.label
    -- Truncate if wider than sidebar
    if vim.fn.strdisplaywidth(icon_label) > width - 2 then
      icon_label = icon_label:sub(1, width - 3) .. "…"
    end
    -- Centre-pad with spaces so the background highlight fills the row
    local pad = width - vim.fn.strdisplaywidth(icon_label)
    local left_pad = math.floor(pad / 2)
    local right_pad = pad - left_pad
    local banner = string.rep(" ", left_pad) .. icon_label .. string.rep(" ", right_pad)
    table.insert(lines, banner)
    -- Line highlight covers the full row (use named format)
    table.insert(highlights, { row = #lines, line_hl = "CodeReviewCommitFilter" })
  end

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

  -- Highlight CI icon on the status line (0-indexed row = #lines - 1)
  if ci_icon and CI_HLS[ci_status] then
    table.insert(highlights, { #lines - 1, 0, #ci_icon, CI_HLS[ci_status] })
  end

  -- Line 4: full-width separator
  table.insert(lines, string.rep("─", width))

  return { lines = lines, highlights = highlights, row_map = row_map }
end

return M
