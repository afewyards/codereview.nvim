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
  local highlights = {}
  local lines = {}

  -- ── Header card ─────────────────────────────────────────────────
  local inner_w = width - 2  -- inside │ ... │
  table.insert(lines, "╭" .. string.rep("─", inner_w) .. "╮")
  table.insert(highlights, { #lines - 1, 0, #lines[#lines], "CodeReviewHeaderCardBorder" })

  -- Line 1: │  #id  title                          state │
  local id_str = "#" .. review.id
  local state_str = review.state or "unknown"
  local title_max = inner_w - #id_str - #state_str - 6  -- 2 pad each side + 2 spaces
  local title = review.title or ""
  if #title > title_max then title = title:sub(1, title_max - 1) .. "…" end
  local gap1 = math.max(1, inner_w - 2 - #id_str - 2 - #title - #state_str)
  local line1 = "│  " .. id_str .. "  " .. title .. string.rep(" ", gap1) .. state_str .. "  │"
  local row1 = #lines
  table.insert(lines, line1)
  table.insert(highlights, { row1, 0, 3, "CodeReviewHeaderCardBorder" })
  table.insert(highlights, { row1, #line1 - 3, #line1, "CodeReviewHeaderCardBorder" })
  local id_start = 3
  table.insert(highlights, { row1, id_start, id_start + #id_str, "CodeReviewHeaderCardId" })
  local title_start = id_start + #id_str + 2
  table.insert(highlights, { row1, title_start, title_start + #title, "CodeReviewHeaderCardTitle" })
  -- Find state position by searching from end
  local state_pos = #line1 - 5 - #state_str  -- 5 = "  │" (3 bytes for │ + 2 spaces)
  local state_hl = ({ opened = "CodeReviewStateOpened", merged = "CodeReviewStateMerged", closed = "CodeReviewStateClosed" })[review.state] or "CodeReviewThreadMeta"
  table.insert(highlights, { row1, state_pos, state_pos + #state_str, state_hl })

  -- Line 2: │  @author  source → target   CI  1/2 approved │
  local pipeline_icon = list_mod.pipeline_icon(review.pipeline_status)
  local author_str = "@" .. review.author
  local branch_str = review.source_branch .. " → " .. (review.target_branch or "main")
  local right_parts = {}
  table.insert(right_parts, pipeline_icon)
  local approved_by = (type(review.approved_by) == "table") and review.approved_by or {}
  local approvals_required = (type(review.approvals_required) == "number") and review.approvals_required or 0
  if approvals_required > 0 or #approved_by > 0 then
    table.insert(right_parts, #approved_by .. "/" .. approvals_required .. " approved")
  end
  if review.merge_status then
    local ms = review.merge_status == "can_be_merged" and "mergeable" or "conflicts"
    table.insert(right_parts, ms)
  end
  local right_str = table.concat(right_parts, "   ")
  local gap2 = math.max(1, inner_w - 2 - #author_str - 2 - #branch_str - 3 - #right_str)
  local line2 = "│  " .. author_str .. "  " .. branch_str .. string.rep(" ", gap2) .. right_str .. "  │"
  local row2 = #lines
  table.insert(lines, line2)
  table.insert(highlights, { row2, 0, 3, "CodeReviewHeaderCardBorder" })
  table.insert(highlights, { row2, #line2 - 3, #line2, "CodeReviewHeaderCardBorder" })
  local a_start = 3
  table.insert(highlights, { row2, a_start, a_start + #author_str, "CodeReviewCommentAuthor" })
  local b_start = a_start + #author_str + 2
  table.insert(highlights, { row2, b_start, b_start + #branch_str + 2, "CodeReviewHeaderBranch" })  -- +2 for → (3 bytes but visually 1 char, offset compensates)

  -- Bottom border
  table.insert(lines, "╰" .. string.rep("─", inner_w) .. "╯")
  table.insert(highlights, { #lines - 1, 0, #lines[#lines], "CodeReviewHeaderCardBorder" })

  -- ── Description section ──────────────────────────────────────────
  local block_result = nil
  if review.description and review.description ~= "" then
    table.insert(lines, "")
    local desc_header_row = #lines
    table.insert(lines, "## Description")
    table.insert(highlights, { desc_header_row, 0, 14, "CodeReviewMdH2" })
    local desc_start = #lines
    block_result = require("codereview.ui.markdown").parse_blocks(review.description, "CodeReviewComment", { width = width })
    for _, bl in ipairs(block_result.lines) do
      table.insert(lines, "  " .. bl)
    end
    for _, h in ipairs(block_result.highlights) do
      table.insert(highlights, { desc_start + h[1], h[2] + 2, h[3] + 2, h[4] })
    end
  end

  -- Adjust code block indents for the 2-space description prefix
  local code_blocks = {}
  if block_result then
    for _, cb in ipairs(block_result.code_blocks) do
      table.insert(code_blocks, {
        start_row = cb.start_row,
        end_row = cb.end_row,
        lang = cb.lang,
        text = cb.text,
        indent = cb.indent + 2,
      })
    end
  end

  return {
    lines = lines,
    highlights = highlights,
    code_blocks = code_blocks,
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

local ACTIVITY_ICONS = {
  { pattern = "assigned",         icon = "\xef\x90\x95", hl = "CodeReviewActivityAssign" },
  { pattern = "added %d+ commit", icon = "\xef\x90\x97", hl = "CodeReviewActivityCommit" },
  { pattern = "review",           icon = "\xef\x90\x9f", hl = "CodeReviewActivityComment" },
  { pattern = "resolved",         icon = "\xef\x90\xae", hl = "CodeReviewActivityResolved" },
  { pattern = "approved",         icon = "\xef\x90\x9d", hl = "CodeReviewActivityApproved" },
  { pattern = "merged",           icon = "\xef\x90\x99", hl = "CodeReviewActivityMerged" },
}
local FALLBACK_ICON = { icon = "\xef\x91\x84", hl = "CodeReviewActivityGeneric" }

local function get_activity_icon(body)
  local lower = (body or ""):lower()
  for _, entry in ipairs(ACTIVITY_ICONS) do
    if lower:match(entry.pattern) then
      return entry
    end
  end
  return FALLBACK_ICON
end

local function strip_html(body)
  local s = (body or ""):gsub("<br%s*/?>", " ")
  s = s:gsub("<[^>]+>", "")
  s = s:gsub("\n", " ")
  return s
end

local function render_thread(result, disc, width, reply_key, resolve_key, is_last)
  local lines = result.lines
  local highlights = result.highlights
  local row_map = result.row_map
  local first_note = disc.notes and disc.notes[1]
  if not first_note then return end

  local resolved = disc.resolved
  if resolved == nil then
    for _, note in ipairs(disc.notes) do
      if note.resolvable ~= nil then
        resolved = note.resolved
        break
      end
    end
  end

  -- Status dot + label: "● Unresolved" or "○ Resolved"
  local status_dot = ""
  local status_label = ""
  if first_note.resolvable ~= nil or disc.resolved ~= nil then
    status_dot = resolved and "○" or "●"
    status_label = resolved and " Resolved" or " Unresolved"
  end
  local status_str = status_dot .. status_label

  local time_str = format_time_short(first_note.created_at)
  local header_meta = time_str ~= "" and (" · " .. time_str) or ""
  local author_str = "@" .. first_note.author
  local left_part = author_str .. header_meta

  local thread_start_row = #lines

  -- Header: @author · time              ● Unresolved
  local gap = math.max(1, width - #left_part - #status_str)
  local header_line = left_part .. string.rep(" ", gap) .. status_str
  table.insert(lines, header_line)
  row_map[thread_start_row] = { type = "thread_start", discussion = disc }

  -- Header highlights
  table.insert(highlights, {thread_start_row, 0, #author_str, "CodeReviewCommentAuthor"})
  if #header_meta > 0 then
    table.insert(highlights, {thread_start_row, #author_str, #author_str + #header_meta, "CodeReviewThreadMeta"})
  end
  if #status_str > 0 then
    local dot_start = #left_part + gap
    table.insert(highlights, {thread_start_row, dot_start, dot_start + #status_dot,
      resolved and "CodeReviewStatusResolved" or "CodeReviewStatusUnresolved"})
    local label_start = dot_start + #status_dot
    table.insert(highlights, {thread_start_row, label_start, label_start + #status_label,
      resolved and "CodeReviewCommentResolved" or "CodeReviewCommentUnresolved"})
  end

  -- Body lines (no prefix)
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
  local arrow_len = #"↪ "  -- ↪ is U+21AA = 3 UTF-8 bytes, + space = 4 bytes
  for i = 2, #disc.notes do
    local reply = disc.notes[i]
    if not reply.system then
      local rt = format_time_short(reply.created_at)
      local rmeta = rt ~= "" and (" · " .. rt) or ""
      local rauthor_str = "@" .. reply.author

      -- Blank line before reply
      local blank_row = #lines
      table.insert(lines, "")
      row_map[blank_row] = { type = "thread", discussion = disc }

      -- Reply header: ↪ @author · time
      local reply_header_row = #lines
      local reply_header = "↪ " .. rauthor_str .. rmeta
      table.insert(lines, reply_header)
      row_map[reply_header_row] = { type = "thread", discussion = disc }

      table.insert(highlights, {reply_header_row, 0, arrow_len, "CodeReviewThreadBorder"})
      table.insert(highlights, {reply_header_row, arrow_len, arrow_len + #rauthor_str, "CodeReviewCommentAuthor"})
      if #rmeta > 0 then
        table.insert(highlights, {reply_header_row, arrow_len + #rauthor_str, arrow_len + #rauthor_str + #rmeta, "CodeReviewThreadMeta"})
      end

      -- Reply body (no prefix)
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

  -- Blank line after thread
  table.insert(lines, "")

  -- Dashed separator between threads (omitted after last)
  if not is_last then
    local sep = string.rep("╌", width)
    local sep_row = #lines
    table.insert(lines, sep)
    table.insert(highlights, {sep_row, 0, #sep, "CodeReviewThreadBorder"})
  end
end

function M.build_activity_lines(discussions, width)
  width = width or 60
  local result = { lines = {}, highlights = {}, row_map = {}, code_blocks = {} }

  if not discussions or #discussions == 0 then
    return result
  end

  local lines = result.lines
  local highlights = result.highlights

  local km = require("codereview.keymaps")
  local reply_key = km.get("reply") or "r"
  local resolve_key = km.get("toggle_resolve") or "gt"

  -- Pass 1: collect system notes
  local system_notes = {}
  for _, disc in ipairs(discussions) do
    local first_note = disc.notes and disc.notes[1]
    if first_note and first_note.system then
      table.insert(system_notes, first_note)
    end
  end

  -- Pass 2: collect general user discussions (exclude inline discussions with position)
  local user_discussions = {}
  for _, disc in ipairs(discussions) do
    local first_note = disc.notes and disc.notes[1]
    if first_note and not first_note.system and not first_note.position then
      table.insert(user_discussions, disc)
    end
  end

  -- ── Activity section ─────────────────────────────────────────────
  table.insert(lines, "")
  local sep1 = string.rep("─", width)
  table.insert(lines, sep1)
  table.insert(highlights, {#lines - 1, 0, #sep1, "CodeReviewMdHr"})
  local act_header_row = #lines
  table.insert(lines, "## Activity")
  table.insert(highlights, {act_header_row, 0, 11, "CodeReviewMdH2"})
  table.insert(lines, "")

  for _, note in ipairs(system_notes) do
    local icon_entry = get_activity_icon(note.body)
    local icon = icon_entry.icon
    local author_str = "@" .. note.author
    local time_str = format_time_short(note.created_at)
    local body_text = strip_html(note.body):sub(1, 80)
    -- Build line: "  {icon} @author body_text   time"
    local left = "  " .. icon .. " " .. author_str .. " " .. body_text
    local right = time_str
    local gap = math.max(1, width - #left - #right)
    local activity_line = left .. string.rep(" ", gap) .. right
    local activity_row = #lines
    table.insert(lines, activity_line)
    -- Highlights: icon (3 bytes), @author, time
    local icon_col = 2
    table.insert(highlights, {activity_row, icon_col, icon_col + 3, icon_entry.hl})
    local author_col = icon_col + 3 + 1  -- after icon + space
    table.insert(highlights, {activity_row, author_col, author_col + #author_str, "CodeReviewCommentAuthor"})
    if #right > 0 then
      local time_col = #left + gap
      table.insert(highlights, {activity_row, time_col, time_col + #right, "CodeReviewActivityTime"})
    end
  end

  -- ── Discussions section ───────────────────────────────────────────
  table.insert(lines, "")
  local sep2 = string.rep("─", width)
  table.insert(lines, sep2)
  table.insert(highlights, {#lines - 1, 0, #sep2, "CodeReviewMdHr"})
  local _, unresolved = M.count_discussions(discussions)
  local disc_header = "## Discussions (" .. unresolved .. " unresolved)"
  local disc_header_row = #lines
  table.insert(lines, disc_header)
  table.insert(highlights, {disc_header_row, 0, #disc_header, "CodeReviewMdH2"})
  table.insert(lines, "")

  for i = #user_discussions, 1, -1 do
    render_thread(result, user_discussions[i], width, reply_key, resolve_key, i == 1)
  end

  return result
end

function M.count_discussions(discussions)
  local total = 0
  local unresolved = 0
  for _, disc in ipairs(discussions or {}) do
    local first_note = disc.notes and disc.notes[1]
    if first_note and not first_note.system and not first_note.position then
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
