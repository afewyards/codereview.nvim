-- lua/codereview/picker/commits.lua
-- Commit picker: build_entries (pure, testable) + pick (opens picker UI).

local M = {}

--- Build picker entries from a list of commits.
--- Always includes an "All changes" entry first, optionally a "Since last review" entry,
--- then one entry per commit.
--- @param commits table[] list of Commit objects
--- @param last_reviewed_sha string? SHA of the last reviewed commit
--- @return table[] picker entries
function M.build_entries(commits, last_reviewed_sha)
  local entries = {}

  table.insert(entries, {
    type = "all",
    display = "  All changes (full MR diff)",
    ordinal = "all changes clear filter",
  })

  if last_reviewed_sha then
    local count = 0
    for i = #commits, 1, -1 do
      if commits[i].sha == last_reviewed_sha then
        break
      end
      count = count + 1
    end
    if count > 0 then
      table.insert(entries, {
        type = "since_last_review",
        from_sha = last_reviewed_sha,
        display = string.format("  Since last review (%d commits)", count),
        ordinal = "since last review",
      })
    end
  end

  for _, c in ipairs(commits) do
    local short = c.short_sha or (c.sha or ""):sub(1, 8)
    local title = c.title or ""
    local title_display = #title > 85 and title:sub(1, 82) .. "..." or title
    local stats = ""
    if c.additions or c.deletions then
      stats = string.format("+%d -%d", c.additions or 0, c.deletions or 0)
    end
    local display = stats ~= "" and string.format("  %s  %s  %s  (%s)", short, title_display, stats, c.author or "")
      or string.format("  %s  %s  (%s)", short, title_display, c.author or "")
    table.insert(entries, {
      type = "commit",
      sha = c.sha,
      title = c.title,
      title_display = title_display,
      author = c.author,
      additions = c.additions,
      deletions = c.deletions,
      display = display,
      ordinal = (c.sha or "") .. " " .. (c.title or "") .. " " .. (c.author or ""),
    })
  end

  return entries
end

--- Open the commit picker UI.
--- @param state table diff viewer state (must have .commits and optionally .last_reviewed_sha)
--- @param on_select function called with the selected entry
function M.pick(state, on_select)
  local entries = M.build_entries(state.commits or {}, state.last_reviewed_sha)

  local default_idx = 1
  if state.commit_filter then
    for i, e in ipairs(entries) do
      if e.sha == state.commit_filter.to_sha then
        default_idx = i
        break
      end
    end
  end

  local picker_mod = require("codereview.picker")
  picker_mod.pick_commits(entries, on_select, { default_selection_index = default_idx })
end

return M
