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

function M.format_mr_preview(entry)
  local desc = entry.review and entry.review.description or ""
  return "# "
    .. entry.title
    .. "\n\n"
    .. "**Branch:** "
    .. (entry.source_branch or "")
    .. "  \n"
    .. "**Updated:** "
    .. (entry.time_str or "")
    .. "\n\n"
    .. (desc ~= "" and desc or "(no description)")
end

function M.format_mr_entry(review, unread_ids)
  local icon = M.pipeline_icon(review.pipeline_status)
  local tvl = require("codereview.mr.thread_virt_lines")
  local time_str = tvl.format_time_relative(review.updated_at)
  local unread = unread_ids and unread_ids[review.id]
  local title = #review.title > 80 and review.title:sub(1, 77) .. "..." or review.title

  return {
    pipeline_icon = icon,
    time_str = time_str,
    unread = unread,
    title_display = title,
    id = review.id,
    title = review.title,
    author = review.author,
    source_branch = review.source_branch,
    target_branch = review.target_branch,
    web_url = review.web_url,
    review = review,
  }
end

function M.format_entries(entries)
  local max_title, max_author, max_id, max_icon = 0, 0, 0, 0
  for _, e in ipairs(entries) do
    max_title = math.max(max_title, #e.title_display, 70)
    max_author = math.max(max_author, #e.author)
    max_id = math.max(max_id, #tostring(e.id))
    max_icon = math.max(max_icon, #e.pipeline_icon)
  end
  local widths = { title = max_title, author = max_author, id = max_id, icon = max_icon }
  for _, e in ipairs(entries) do
    e._col_widths = widths
    e.display = string.format(
      "%s%-" .. max_icon .. "s #%-" .. max_id .. "d %-" .. max_title .. "s  @%-" .. max_author .. "s  %s",
      e.unread and "*" or " ",
      e.pipeline_icon,
      e.id,
      e.title_display,
      e.author,
      e.time_str
    )
  end
  return widths
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
      M.format_entries(entries)
      callback(entries)
    end)
  end)
end

return M
