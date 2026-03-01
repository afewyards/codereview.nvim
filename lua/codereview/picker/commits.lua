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
      if commits[i].sha == last_reviewed_sha then break end
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
    local display = string.format("  %s  %s  (%s)", short, c.title or "", c.author or "")
    table.insert(entries, {
      type = "commit",
      sha = c.sha,
      title = c.title,
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

  local picker_mod = require("codereview.picker")
  local adapter = picker_mod.detect()
  if not adapter then
    vim.notify("No picker available (telescope/fzf/snacks)", vim.log.levels.WARN)
    return
  end

  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    vim.notify("Commit picker requires telescope", vim.log.levels.WARN)
    return
  end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "Commits",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        return { value = entry, display = entry.display, ordinal = entry.ordinal }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local sel = action_state.get_selected_entry()
        if sel then on_select(sel.value) end
      end)
      return true
    end,
  }):find()
end

return M
