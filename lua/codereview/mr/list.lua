local client = require("codereview.api.client")
local endpoints = require("codereview.api.endpoints")
local git = require("codereview.git")
local M = {}

local PIPELINE_ICONS = {
  success = "[ok]",
  failed = "[fail]",
  running = "[..]",
  pending = "[..]",
  canceled = "[--]",
  skipped = "[--]",
  manual = "[||]",
  created = "[..]",
}

function M.pipeline_icon(status)
  if not status then return "[--]" end
  return PIPELINE_ICONS[status] or "[??]"
end

function M.format_mr_entry(mr)
  local pipeline_status = mr.head_pipeline and mr.head_pipeline.status or nil
  local icon = M.pipeline_icon(pipeline_status)
  local display = string.format(
    "%s !%-4d %-50s @%-15s %s",
    icon,
    mr.iid,
    mr.title:sub(1, 50),
    mr.author.username,
    mr.source_branch
  )

  return {
    display = display,
    iid = mr.iid,
    title = mr.title,
    author = mr.author.username,
    source_branch = mr.source_branch,
    target_branch = mr.target_branch,
    web_url = mr.web_url,
    mr = mr,
  }
end

function M.fetch(opts, callback)
  opts = opts or {}
  vim.notify("Fetching merge requests...", vim.log.levels.INFO)
  local base_url, project = git.detect_project()
  if not base_url or not project then
    callback(nil, "Could not detect GitLab project")
    return
  end

  local encoded = client.encode_project(project)
  local query = {
    state = opts.state or "opened",
    scope = opts.scope or "all",
    per_page = opts.per_page or 50,
  }

  local result, err = client.get(base_url, endpoints.mr_list(encoded), { query = query })
  if not result then
    callback(nil, err)
    return
  end

  local entries = {}
  for _, mr in ipairs(result.data) do
    table.insert(entries, M.format_mr_entry(mr))
  end

  callback(entries)
end

return M
