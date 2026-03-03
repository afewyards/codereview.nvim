-- lua/codereview/mr/sidebar_components/commits.lua
-- Commits component for the diff sidebar.

local M = {}

local COLLAPSED_THRESHOLD = 8

--- Append the Commits section rows to lines and record row_map entries.
--- @param state table  diff viewer state (needs .commits, .commit_filter, .collapsed_commits)
--- @param lines table  mutable lines array
--- @param row_map table  mutable row_map (1-indexed)
--- @param width number  sidebar display width for truncation
function M.render(state, lines, row_map, width)
  local commits = state.commits or {}
  if #commits == 0 then
    return
  end

  if state.collapsed_commits == nil then
    state.collapsed_commits = #commits > COLLAPSED_THRESHOLD
  end

  local prefix = state.collapsed_commits and "▸" or "▾"
  local header = string.format(" %s Commits (%d) ", prefix, #commits)
  local pad = width - vim.fn.strdisplaywidth(header)
  if pad > 0 then
    header = header .. string.rep("─", pad)
  end
  table.insert(lines, header)
  row_map[#lines] = { type = "commits_header" }

  if state.collapsed_commits then
    table.insert(lines, "")
    return
  end

  for _, commit in ipairs(commits) do
    local is_active = state.commit_filter and state.commit_filter.to_sha == commit.sha
    local icon = is_active and " ● " or "   "
    local ellipsis = "…"
    local max_title = width - #icon - 1
    local title = commit.title or ""
    if vim.fn.strdisplaywidth(title) > max_title then
      title = title:sub(1, max_title - #ellipsis) .. ellipsis
    end
    table.insert(lines, icon .. title)
    row_map[#lines] = { type = "commit", sha = commit.sha, title = commit.title }
  end

  if state.last_reviewed_sha then
    local count = 0
    local found = false
    for i = #commits, 1, -1 do
      if commits[i].sha == state.last_reviewed_sha then
        found = true
        break
      end
      count = count + 1
    end
    if found and count > 0 then
      table.insert(lines, string.format("   ▸ Since last review (%d new)", count))
      row_map[#lines] = {
        type = "since_last_review",
        from_sha = state.last_reviewed_sha,
        to_sha = state.review and state.review.head_sha,
        count = count,
      }
    end
  end

  table.insert(lines, "")
end

return M
