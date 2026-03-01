local M = {}

local GITLAB_ITEMS = {
  { type = "checkbox", key = "squash", label = "Squash commits", checked = false },
  { type = "checkbox", key = "remove_source_branch", label = "Delete source branch", checked = false },
  { type = "checkbox", key = "auto_merge", label = "Merge when pipeline succeeds", checked = false },
}

local GITHUB_ITEMS = {
  { type = "cycle", key = "merge_method", label = "Method", values = { "merge", "squash", "rebase" }, idx = 1 },
  { type = "checkbox", key = "remove_source_branch", label = "Delete source branch", checked = false },
}

--- Build item list for the given platform.
--- @param platform string "gitlab"|"github"
--- @return table[]
function M.build_items(platform)
  local template = platform == "github" and GITHUB_ITEMS or GITLAB_ITEMS
  local items = {}
  for _, t in ipairs(template) do
    local item = {}
    for k, v in pairs(t) do item[k] = v end
    if item.values then
      local vals = {}
      for _, v in ipairs(item.values) do vals[#vals + 1] = v end
      item.values = vals
    end
    items[#items + 1] = item
  end
  return items
end

--- Render a single item as a display line.
--- @param item table
--- @return string
function M.render_line(item)
  if item.type == "checkbox" then
    local mark = item.checked and "x" or " "
    return "  [" .. mark .. "] " .. item.label
  elseif item.type == "cycle" then
    return "  " .. item.label .. ": ◀ " .. item.values[item.idx] .. " ▶"
  end
  return ""
end

--- Collect current item states into an opts table for actions.merge().
--- @param items table[]
--- @return table
function M.collect_opts(items)
  local opts = {}
  for _, item in ipairs(items) do
    if item.type == "checkbox" then
      if item.checked then opts[item.key] = true end
    elseif item.type == "cycle" then
      opts[item.key] = item.values[item.idx]
    end
  end
  return opts
end

return M
