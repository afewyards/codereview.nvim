local providers = require("codereview.providers")
local client = require("codereview.api.client")
local markdown = require("codereview.ui.markdown")
local list_mod = require("codereview.mr.list")
local tvl = require("codereview.mr.thread_virt_lines")
local diff_state_mod = require("codereview.mr.diff_state")

local M = {}

function M.format_time(iso_str)
  if not iso_str then return "" end
  local y, mo, d, h, mi = iso_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
  if not y then return iso_str end
  return string.format("%s-%s-%s %s:%s", y, mo, d, h, mi)
end

function M.build_header_lines(review, width)
  width = width or 70
  local pipeline_icon = list_mod.pipeline_icon(review.pipeline_status)
  local highlights = {}
  local lines = {
    string.format("#%d: %s", review.id, review.title),
    "",
    string.format("Author: @%s   Branch: %s -> %s", review.author, review.source_branch, review.target_branch or "main"),
    string.format("Status: %s   Pipeline: %s", review.state, pipeline_icon),
  }

  local approved_by = (type(review.approved_by) == "table") and review.approved_by or {}
  local approvals_required = (type(review.approvals_required) == "number") and review.approvals_required or 0
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

  table.insert(lines, string.rep("-", width))

  local block_result = nil
  if review.description and review.description ~= "" then
    table.insert(lines, "")
    local desc_start = #lines
    block_result = markdown.parse_blocks(review.description, "CodeReviewComment", { width = width })
    for _, bl in ipairs(block_result.lines) do
      table.insert(lines, bl)
    end
    for _, h in ipairs(block_result.highlights) do
      table.insert(highlights, { desc_start + h[1], h[2], h[3], h[4] })
    end
  end

  return {
    lines = lines,
    highlights = highlights,
    code_blocks = block_result and block_result.code_blocks or {},
  }
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

local format_time_short = tvl.format_time_relative

function M.build_activity_lines(discussions, width)
  width = width or 60
  local result = { lines = {}, highlights = {}, row_map = {}, code_blocks = {} }

  if not discussions or #discussions == 0 then
    return result
  end

  local lines = result.lines
  local highlights = result.highlights
  local row_map = result.row_map

  table.insert(lines, "")
  local activity_line = "-- Activity " .. string.rep("-", 58)
  table.insert(lines, activity_line)
  table.insert(highlights, {#lines - 1, 0, #activity_line, "CodeReviewThreadBorder"})
  table.insert(lines, "")

  local km = require("codereview.keymaps")
  local reply_key = km.get("reply") or "r"
  local resolve_key = km.get("toggle_resolve") or "gt"

  for _, disc in ipairs(discussions) do
    local first_note = disc.notes and disc.notes[1]
    if first_note and not first_note.position then
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

        -- Header highlights
        table.insert(highlights, {thread_start_row, 0, 3, "CodeReviewThreadBorder"})
        table.insert(highlights, {thread_start_row, 4, 4 + #header_text, "CodeReviewCommentAuthor"})
        if #header_meta > 0 then
          table.insert(highlights, {thread_start_row, 4 + #header_text, 4 + #header_text + #header_meta, "CodeReviewThreadMeta"})
        end
        if #status_str > 0 then
          local status_start = 4 + #header_text + #header_meta
          local status_hl = resolved and "CodeReviewCommentResolved" or "CodeReviewCommentUnresolved"
          table.insert(highlights, {thread_start_row, status_start, status_start + #status_str, status_hl})
        end
        if fill > 0 then
          local fill_start = 4 + #header_text + #header_meta + #status_str
          table.insert(highlights, {thread_start_row, fill_start, fill_start + fill * 3, "CodeReviewThreadBorder"})
        end

        -- Body lines parsed for block-level markdown
        local body_start = #lines
        local body_result = markdown.parse_blocks(first_note.body or "", "CodeReviewComment", { width = width })
        for _, bl in ipairs(body_result.lines) do
          local row = #lines
          table.insert(lines, bl)
          row_map[row] = { type = "thread", discussion = disc }
        end
        for _, h in ipairs(body_result.highlights) do
          table.insert(highlights, { body_start + h[1], h[2], h[3], h[4] })
        end
        for _, cb in ipairs(body_result.code_blocks) do
          table.insert(result.code_blocks, {
            start_row = body_start + cb.start_row,
            end_row = body_start + cb.end_row,
            lang = cb.lang,
            text = cb.text,
            indent = cb.indent,
          })
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

            -- Reply header highlights
            table.insert(highlights, {reply_header_row, 0, 3, "CodeReviewThreadBorder"})
            local rauthor_len = 1 + #reply.author
            table.insert(highlights, {reply_header_row, 4, 4 + rauthor_len, "CodeReviewCommentAuthor"})
            if #rmeta > 0 then
              table.insert(highlights, {reply_header_row, 4 + rauthor_len, 4 + rauthor_len + #rmeta, "CodeReviewThreadMeta"})
            end

            local reply_body_start = #lines
            local reply_result = markdown.parse_blocks(reply.body or "", "CodeReviewComment", { width = width })
            for _, rl in ipairs(reply_result.lines) do
              local rrow = #lines
              table.insert(lines, rl)
              row_map[rrow] = { type = "thread", discussion = disc }
            end
            for _, h in ipairs(reply_result.highlights) do
              table.insert(highlights, { reply_body_start + h[1], h[2], h[3], h[4] })
            end
            for _, cb in ipairs(reply_result.code_blocks) do
              table.insert(result.code_blocks, {
                start_row = reply_body_start + cb.start_row,
                end_row = reply_body_start + cb.end_row,
                lang = cb.lang,
                text = cb.text,
                indent = cb.indent,
              })
            end
          end
        end

        -- Footer: └ r:reply  gt:un/resolve ──────────────────────
        local footer_text = disc.is_draft
          and string.format("%s:un/resolve", resolve_key)
          or string.format("%s:reply  %s:un/resolve", reply_key, resolve_key)
        local footer_fill = math.max(0, 44 - #footer_text)
        local footer_row = #lines
        table.insert(lines, string.format("└ %s%s", footer_text, string.rep("─", footer_fill)))
        row_map[footer_row] = { type = "thread", discussion = disc }

        -- Footer highlights
        table.insert(highlights, {footer_row, 0, 3, "CodeReviewThreadBorder"})
        table.insert(highlights, {footer_row, 4, 4 + #footer_text, "CodeReviewFloatFooterKey"})
        if footer_fill > 0 then
          local ffill_start = 4 + #footer_text
          table.insert(highlights, {footer_row, ffill_start, ffill_start + footer_fill * 3, "CodeReviewThreadBorder"})
        end

        table.insert(lines, "")
      end
    end
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

--- Apply resumed server-side drafts to state. Enters review session.
function M._apply_resumed_drafts(state, server_drafts)
  local session = require("codereview.review.session")
  session.start()
  for _, d in ipairs(server_drafts) do
    table.insert(state.local_drafts, d)
    table.insert(state.discussions, d)
  end
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

  diff.close_active()
  local layout = split.create()

  local state = diff_state_mod.create_state({
    view_mode = "summary",
    review = review,
    provider = provider,
    ctx = ctx,
    entry = entry,
    files = files,
    layout = layout,
    discussions = discussions,
  })

  -- Fetch current user for note authorship checks (edit/delete guards)
  local client_mod = require("codereview.api.client")
  local user = provider.get_current_user(client_mod, ctx)
  if user then state.current_user = user end

  diff.render_sidebar(layout.sidebar_buf, state)
  diff.render_summary(layout.main_buf, state)
  diff.setup_keymaps(layout, state)
  vim.api.nvim_set_current_win(layout.main_win)

  -- Check for server-side draft comments
  local drafts_mod = require("codereview.review.drafts")
  drafts_mod.check_and_prompt(provider, client_mod, ctx, review, function(server_drafts)
    if server_drafts then
      M._apply_resumed_drafts(state, server_drafts)
      diff.render_sidebar(layout.sidebar_buf, state)
      if state.view_mode == "summary" then
        diff.render_summary(layout.main_buf, state)
      end
    end
  end)
end

return M
