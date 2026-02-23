local providers = require("codereview.providers")
local client = require("codereview.api.client")

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

function M.format_mr_entry(review)
  local icon = M.pipeline_icon(review.pipeline_status)
  local display = string.format(
    "%s #%-4d %-50s @%-15s %s",
    icon,
    review.id,
    review.title:sub(1, 50),
    review.author,
    review.source_branch
  )

  return {
    display = display,
    id = review.id,
    title = review.title,
    author = review.author,
    source_branch = review.source_branch,
    target_branch = review.target_branch,
    web_url = review.web_url,
    review = review,
  }
end

function M.fetch(opts, callback)
  opts = opts or {}
  local ok, reviews, fetch_err = pcall(function()
    local prov, pctx, perr = providers.detect()
    if not prov then return nil, perr end
    return prov.list_reviews(client, pctx, opts)
  end)

  if not ok then
    callback(nil, tostring(reviews))
    return
  end

  if not reviews then
    callback(nil, fetch_err)
    return
  end

  local entries = {}
  for _, review in ipairs(reviews) do
    table.insert(entries, M.format_mr_entry(review))
  end
  callback(entries)
end

return M
