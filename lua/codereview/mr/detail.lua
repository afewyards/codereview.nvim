local client = require("codereview.api.client")
local endpoints = require("codereview.api.endpoints")
local git = require("codereview.git")
local markdown = require("codereview.ui.markdown")
local list_mod = require("codereview.mr.list")
local M = {}

function M.format_time(iso_str)
  if not iso_str then return "" end
  local y, mo, d, h, mi = iso_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
  if not y then return iso_str end
  return string.format("%s-%s-%s %s:%s", y, mo, d, h, mi)
end

function M.build_header_lines(mr)
  local pipeline_icon = list_mod.pipeline_icon(mr.head_pipeline and mr.head_pipeline.status)
  local lines = {
    string.format("MR !%d: %s", mr.iid, mr.title),
    "",
    string.format("Author: @%s   Branch: %s -> %s", mr.author.username, mr.source_branch, mr.target_branch or "main"),
    string.format("Status: %s   Pipeline: %s", mr.state, pipeline_icon),
  }

  local approved_by = mr.approved_by or {}
  local approvals_required = mr.approvals_before_merge or 0
  if approvals_required > 0 or #approved_by > 0 then
    local approver_names = {}
    for _, a in ipairs(approved_by) do
      table.insert(approver_names, "@" .. a.user.username)
    end
    table.insert(lines, string.format(
      "Approvals: %d/%d  %s",
      #approved_by,
      approvals_required,
      #approver_names > 0 and table.concat(approver_names, ", ") or ""
    ))
  end

  table.insert(lines, string.rep("-", 70))

  if mr.description and mr.description ~= "" then
    table.insert(lines, "")
    for _, line in ipairs(markdown.to_lines(mr.description)) do
      table.insert(lines, line)
    end
  end

  return lines
end

function M.build_activity_lines(discussions)
  local lines = {}

  if not discussions or #discussions == 0 then
    return lines
  end

  table.insert(lines, "")
  table.insert(lines, "-- Activity " .. string.rep("-", 58))
  table.insert(lines, "")

  for _, disc in ipairs(discussions) do
    local first_note = disc.notes and disc.notes[1]
    if not first_note then goto continue end

    if first_note.position then goto continue end

    if first_note.system then
      table.insert(lines, string.format(
        "  - @%s %s (%s)",
        first_note.author.username,
        first_note.body:gsub("\n", " "):sub(1, 80),
        M.format_time(first_note.created_at)
      ))
    else
      table.insert(lines, string.format(
        "  @%s (%s)",
        first_note.author.username,
        M.format_time(first_note.created_at)
      ))
      for _, body_line in ipairs(markdown.to_lines(first_note.body)) do
        table.insert(lines, "  " .. body_line)
      end

      for i = 2, #disc.notes do
        local reply = disc.notes[i]
        if not reply.system then
          table.insert(lines, string.format(
            "    -> @%s: %s",
            reply.author.username,
            reply.body:gsub("\n", " "):sub(1, 80)
          ))
        end
      end

      table.insert(lines, "")
    end

    ::continue::
  end

  return lines
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

function M.open(mr_entry)
  vim.notify("Loading MR details...", vim.log.levels.INFO)
  local base_url, project = git.detect_project()
  if not base_url or not project then
    vim.notify("Could not detect GitLab project", vim.log.levels.ERROR)
    return
  end

  local encoded = client.encode_project(project)

  local mr_result, err = client.get(base_url, endpoints.mr_detail(encoded, mr_entry.iid))
  if not mr_result then
    vim.notify("Failed to load MR: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end
  local mr = mr_result.data

  local discussions = client.paginate_all(base_url, endpoints.discussions(encoded, mr_entry.iid)) or {}

  local diff_result = client.get(base_url, endpoints.mr_diffs(encoded, mr_entry.iid))
  local files = diff_result and diff_result.data or {}
  if type(files) ~= "table" then files = {} end

  local diff = require("codereview.mr.diff")
  local split = require("codereview.ui.split")
  local config = require("codereview.config")
  local cfg = config.get()

  local layout = split.create()

  local state = {
    view_mode = "summary",
    mr = mr,
    mr_entry = mr_entry,
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
  }

  diff.render_sidebar(layout.sidebar_buf, state)
  diff.render_summary(layout.main_buf, state)
  diff.setup_keymaps(layout, state)
  vim.api.nvim_set_current_win(layout.main_win)
end

return M
