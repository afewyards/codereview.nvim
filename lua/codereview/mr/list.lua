local providers = require("codereview.providers")

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
  if not status then
    return "[--]"
  end
  return PIPELINE_ICONS[status] or "[??]"
end

function M.format_mr_entry(review, unread_ids)
  local icon = M.pipeline_icon(review.pipeline_status)
  local tvl = require("codereview.mr.thread_virt_lines")
  local time_str = tvl.format_time_relative(review.updated_at)
  local unread = unread_ids and unread_ids[review.id] and "*" or " "
  local display = string.format(
    "%s%s #%-4d %-50s @%-15s %-10s %s",
    unread,
    icon,
    review.id,
    review.title:sub(1, 50),
    review.author,
    time_str,
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
  require("plenary.async").run(function()
    local async_client = require("codereview.api.async_client")
    local ok, reviews, fetch_err = pcall(function()
      local prov, pctx, perr = providers.detect()
      if not prov then
        return nil, perr
      end
      return prov.list_reviews(async_client, pctx, opts or {})
    end)

    local prov, pctx = providers.detect()
    local unread_ids = {}
    if prov and prov.get_unread_mr_ids then
      unread_ids = prov.get_unread_mr_ids(async_client, pctx) or {}
    end

    vim.schedule(function()
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
        table.insert(entries, M.format_mr_entry(review, unread_ids))
      end
      callback(entries)
    end)
  end)
end

return M
