-- lua/codereview/mr/sidebar_components/status.lua
-- Pure render: session status section.
-- Returns { lines, highlights, row_map } without touching a buffer.

local M = {}

local function count_session_stats(state)
  local stats = { drafts = 0, ai_accepted = 0, ai_dismissed = 0, ai_pending = 0, threads = 0, unresolved = 0 }
  for _ in ipairs(state.local_drafts or {}) do
    stats.drafts = stats.drafts + 1
  end
  for _, s in ipairs(state.ai_suggestions or {}) do
    if s.status == "accepted" or s.status == "edited" then
      stats.ai_accepted = stats.ai_accepted + 1
    elseif s.status == "dismissed" then
      stats.ai_dismissed = stats.ai_dismissed + 1
    elseif s.status == "pending" then
      stats.ai_pending = stats.ai_pending + 1
    end
  end
  for _, d in ipairs(state.discussions or {}) do
    if not d.local_draft then
      stats.threads = stats.threads + 1
      if not d.resolved then
        stats.unresolved = stats.unresolved + 1
      end
    end
  end
  return stats
end

--- Render the session status section.
--- @param state table  diff viewer state
--- @param _width integer  sidebar width (reserved for future use)
--- @return { lines: string[], highlights: table[], row_map: table }
function M.render(state, _width)
  local session = require("codereview.review.session")
  local sess = session.get()

  if not sess.active then
    return { lines = {}, highlights = {}, row_map = {} }
  end

  local lines = {}
  local highlights = {}
  local row_map = {}
  local stats = count_session_stats(state)

  -- Status line
  if sess.ai_pending then
    if sess.ai_total > 0 and sess.ai_completed > 0 then
      table.insert(lines, string.format("⟳ AI reviewing… %d/%d", sess.ai_completed, sess.ai_total))
    else
      table.insert(lines, "⟳ AI reviewing…")
    end
    highlights[#highlights + 1] = { row = #lines, line_hl = "CodeReviewSpinner" }
  else
    table.insert(lines, "● Review in progress")
    highlights[#highlights + 1] = { row = #lines, line_hl = "CodeReviewFileAdded" }
  end
  row_map.status = #lines

  -- Drafts + AI stats line
  local parts = {}
  if stats.drafts > 0 then
    table.insert(parts, string.format("✎ %d drafts", stats.drafts))
  end
  if state.ai_suggestions then
    local ai_parts = {}
    if stats.ai_accepted > 0 then table.insert(ai_parts, "✓" .. stats.ai_accepted) end
    if stats.ai_dismissed > 0 then table.insert(ai_parts, "✗" .. stats.ai_dismissed) end
    if stats.ai_pending > 0 then table.insert(ai_parts, "⏳" .. stats.ai_pending) end
    if #ai_parts > 0 then
      table.insert(parts, table.concat(ai_parts, " ") .. " AI")
    end
  end
  if #parts > 0 then
    local drafts_line = table.concat(parts, "  ")
    table.insert(lines, drafts_line)
    row_map.drafts = #lines
    local segments = {
      { pat = "✓%d+", hl = "CodeReviewFileAdded" },
      { pat = "✗%d+", hl = "CodeReviewFileDeleted" },
      { pat = "⏳%d+", hl = "CodeReviewHidden" },
    }
    for _, seg in ipairs(segments) do
      local s, e = string.find(drafts_line, seg.pat)
      if s then
        highlights[#highlights + 1] = { row = #lines, col_start = s - 1, col_end = e, word_hl = seg.hl }
      end
    end
  end

  -- Threads line
  if stats.threads > 0 then
    local tline = string.format("💬 %d threads", stats.threads)
    if stats.unresolved > 0 then
      tline = tline .. string.format("  ⚠ %d open", stats.unresolved)
    end
    table.insert(lines, tline)
    row_map.threads = #lines
    if stats.unresolved > 0 then
      highlights[#highlights + 1] = { row = #lines, line_hl = "CodeReviewCommentUnresolved" }
    end
  end

  return { lines = lines, highlights = highlights, row_map = row_map }
end

return M
