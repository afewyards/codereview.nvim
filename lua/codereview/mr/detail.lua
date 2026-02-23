local providers = require("codereview.providers")
local client = require("codereview.api.client")
local markdown = require("codereview.ui.markdown")
local list_mod = require("codereview.mr.list")

local M = {}

function M.format_time(iso_str)
  if not iso_str then return "" end
  local y, mo, d, h, mi = iso_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
  if not y then return iso_str end
  return string.format("%s-%s-%s %s:%s", y, mo, d, h, mi)
end

function M.build_header_lines(review)
  local pipeline_icon = list_mod.pipeline_icon(review.pipeline_status)
  local lines = {
    string.format("#%d: %s", review.id, review.title),
    "",
    string.format("Author: @%s   Branch: %s -> %s", review.author, review.source_branch, review.target_branch or "main"),
    string.format("Status: %s   Pipeline: %s", review.state, pipeline_icon),
  }

  local approved_by = review.approved_by or {}
  local approvals_required = review.approvals_required or 0
  if approvals_required > 0 or #approved_by > 0 then
    local approver_names = {}
    for _, name in ipairs(approved_by) do
      table.insert(approver_names, "@" .. name)
    end
    table.insert(lines, string.format(
      "Approvals: %d/%d  %s",
      #approved_by,
      approvals_required,
      #approver_names > 0 and table.concat(approver_names, ", ") or ""
    ))
  end

  table.insert(lines, string.rep("-", 70))

  if review.description and review.description ~= "" then
    table.insert(lines, "")
    for _, line in ipairs(markdown.to_lines(review.description)) do
      table.insert(lines, line)
    end
  end

  return lines
end

local function wrap_text(text, width)
  local result = {}
  for _, paragraph in ipairs(vim.split(text or "", "\n")) do
    if paragraph == "" then
      table.insert(result, "")
    elseif #paragraph <= width then
      table.insert(result, paragraph)
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        if line ~= "" and #line + #word + 1 > width then
          table.insert(result, line)
          line = word
        else
          line = line == "" and word or (line .. " " .. word)
        end
      end
      if line ~= "" then table.insert(result, line) end
    end
  end
  return result
end

local function format_time_short(iso_str)
  if not iso_str then return "" end
  local mo, d, h, mi = iso_str:match("%d+-(%d+)-(%d+)T(%d+):(%d+)")
  if not mo then return "" end
  return string.format("%s/%s %s:%s", mo, d, h, mi)
end

function M.build_activity_lines(discussions)
  local result = { lines = {}, highlights = {}, row_map = {} }

  if not discussions or #discussions == 0 then
    return result
  end

  local lines = result.lines
  local row_map = result.row_map

  table.insert(lines, "")
  table.insert(lines, "-- Activity " .. string.rep("-", 58))
  table.insert(lines, "")

  local km = require("codereview.keymaps")
  local reply_key = km.get("reply") or "r"
  local resolve_key = km.get("toggle_resolve") or "gt"
  local footer_text = string.format("%s:reply  %s:un/resolve", reply_key, resolve_key)

  for _, disc in ipairs(discussions) do
    local first_note = disc.notes and disc.notes[1]
    if not first_note then goto continue end

    if first_note.position then goto continue end

    if first_note.system then
      table.insert(lines, string.format(
        "  - @%s %s (%s)",
        first_note.author,
        first_note.body:gsub("\n", " "):sub(1, 80),
        M.format_time(first_note.created_at)
      ))
    else
      local resolved = disc.resolved
      if resolved == nil then
        for _, note in ipairs(disc.notes) do
          if note.resolvable ~= nil then
            resolved = note.resolved
            break
          end
        end
      end

      local status_str = ""
      if first_note.resolvable ~= nil or disc.resolved ~= nil then
        status_str = resolved and " Resolved " or " Unresolved "
      end

      local time_str = format_time_short(first_note.created_at)
      local header_meta = time_str ~= "" and (" · " .. time_str) or ""
      local header_text = "@" .. first_note.author
      local fill = math.max(0, 62 - #header_text - #header_meta - #status_str)

      -- Row offset is 0-indexed from start of lines table
      local thread_start_row = #lines

      -- Header: ┌ @author · MM/DD HH:MM  Resolved/Unresolved ──────
      table.insert(lines, string.format(
        "┌ %s%s%s%s",
        header_text,
        header_meta,
        status_str,
        string.rep("─", fill)
      ))
      row_map[thread_start_row] = { type = "thread_start", discussion = disc }

      -- Body lines (raw markdown, no prefix so treesitter can render)
      for _, bl in ipairs(vim.split(first_note.body or "", "\n")) do
        local row = #lines
        table.insert(lines, bl)
        row_map[row] = { type = "thread", discussion = disc }
      end

      -- Replies
      for i = 2, #disc.notes do
        local reply = disc.notes[i]
        if not reply.system then
          local rt = format_time_short(reply.created_at)
          local rmeta = rt ~= "" and (" · " .. rt) or ""
          local sep_row = #lines
          table.insert(lines, "")
          row_map[sep_row] = { type = "thread", discussion = disc }

          local reply_header_row = #lines
          table.insert(lines, string.format("↪ @%s%s", reply.author, rmeta))
          row_map[reply_header_row] = { type = "thread", discussion = disc }

          for _, rl in ipairs(vim.split(reply.body or "", "\n")) do
            local rrow = #lines
            table.insert(lines, rl)
            row_map[rrow] = { type = "thread", discussion = disc }
          end
        end
      end

      -- Footer: └ r:reply  gt:un/resolve ──────────────────────
      local footer_fill = math.max(0, 44 - #footer_text)
      local footer_row = #lines
      table.insert(lines, string.format("└ %s%s", footer_text, string.rep("─", footer_fill)))
      row_map[footer_row] = { type = "thread", discussion = disc }

      table.insert(lines, "")
    end

    ::continue::
  end

  return result
end

function M.count_discussions(discussions)
  local total = 0
  local unresolved = 0
  for _, disc in ipairs(discussions or {}) do
    if disc.notes and disc.notes[1] and not disc.notes[1].system then
      total = total + 1
      for _, note in ipairs(disc.notes) do
        if note.resolvable and not note.resolved then
          unresolved = unresolved + 1
          break
        end
      end
    end
  end
  return total, unresolved
end

function M.open(entry)
  local ok, provider, ctx, review, discussions, files = pcall(function()
    local prov, pctx, perr = providers.detect()
    if not prov then error(perr or "Could not detect platform") end

    local rev, review_err = prov.get_review(client, pctx, entry.id)
    if not rev then error("Failed to load MR: " .. (review_err or "unknown error")) end

    local disc, disc_err = prov.get_discussions(client, pctx, rev)
    if not disc then
      vim.notify("Failed to load discussions: " .. (disc_err or "unknown error"), vim.log.levels.WARN)
      disc = {}
    end

    local f, diffs_err = prov.get_diffs(client, pctx, rev)
    if not f then
      vim.notify("Failed to load diffs: " .. (diffs_err or "unknown error"), vim.log.levels.WARN)
      f = {}
    end

    return prov, pctx, rev, disc, f
  end)

  if not ok then
    vim.notify(tostring(provider), vim.log.levels.ERROR)
    return
  end

  local diff = require("codereview.mr.diff")
  local split = require("codereview.ui.split")
  local config = require("codereview.config")
  local cfg = config.get()

  local layout = split.create()

  local state = {
    view_mode = "summary",
    review = review,
    provider = provider,
    ctx = ctx,
    entry = entry,
    files = files,
    discussions = discussions,
    current_file = 1,
    layout = layout,
    line_data_cache = {},
    row_disc_cache = {},
    sidebar_row_map = {},
    collapsed_dirs = {},
    context = cfg.diff.context,
    scroll_mode = #files <= cfg.diff.scroll_threshold,
    file_sections = {},
    scroll_line_data = {},
    scroll_row_disc = {},
    file_contexts = {},
    ai_suggestions = nil,
    row_ai_cache = {},
    scroll_row_ai = {},
    local_drafts = {},
    summary_row_map = {},
  }

  diff.render_sidebar(layout.sidebar_buf, state)
  diff.render_summary(layout.main_buf, state)
  diff.setup_keymaps(layout, state)
  vim.api.nvim_set_current_win(layout.main_win)
end

return M
