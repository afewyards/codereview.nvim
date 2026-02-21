local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local markdown = require("glab_review.ui.markdown")
local list_mod = require("glab_review.mr.list")
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
        first_note.body,
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

  local lines = M.build_header_lines(mr)
  local activity_lines = M.build_activity_lines(discussions)
  for _, line in ipairs(activity_lines) do
    table.insert(lines, line)
  end

  local total, unresolved = M.count_discussions(discussions)
  table.insert(lines, "")
  table.insert(lines, string.rep("-", 70))
  table.insert(lines, string.format(
    "  %d discussions (%d unresolved)",
    total, unresolved
  ))
  table.insert(lines, "")
  table.insert(lines, "  [d]iff  [c]omment  [a]pprove  [A]I review  [p]ipeline  [m]erge  [R]efresh  [q]uit")

  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(#lines, vim.o.lines - 6)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  markdown.set_buf_markdown(buf)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = string.format(" MR !%d ", mr.iid),
    title_pos = "center",
  })

  vim.b[buf].glab_review_mr = mr
  vim.b[buf].glab_review_discussions = discussions

  local map_opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, map_opts)
  vim.keymap.set("n", "d", function()
    vim.api.nvim_win_close(win, true)
    vim.notify("Diff view (Stage 3)", vim.log.levels.WARN)
  end, map_opts)
  vim.keymap.set("n", "p", function()
    vim.notify("Pipeline view (Stage 4)", vim.log.levels.WARN)
  end, map_opts)
  vim.keymap.set("n", "A", function()
    vim.notify("AI review (Stage 5)", vim.log.levels.WARN)
  end, map_opts)
  vim.keymap.set("n", "a", function()
    vim.notify("Approve (Stage 3)", vim.log.levels.WARN)
  end, map_opts)
  vim.keymap.set("n", "o", function()
    if mr.web_url then
      vim.ui.open(mr.web_url)
    end
  end, map_opts)
  vim.keymap.set("n", "c", function()
    vim.ui.input({ prompt = "Comment on MR: " }, function(input)
      if not input or input == "" then return end
      local b_url, proj = git.detect_project()
      if not b_url or not proj then return end
      local enc = client.encode_project(proj)
      client.post(b_url, endpoints.discussions(enc, mr.iid), {
        body = { body = input },
      })
      vim.notify("Comment posted", vim.log.levels.INFO)
    end)
  end, map_opts)
  vim.keymap.set("n", "m", function()
    vim.ui.select({ "Merge", "Merge when pipeline succeeds", "Cancel" }, {
      prompt = string.format("Merge MR !%d?", mr.iid),
    }, function(choice)
      if not choice or choice == "Cancel" then return end
      local ok, actions = pcall(require, "glab_review.mr.actions")
      if not ok then
        vim.notify("Merge actions not yet implemented (Stage 3)", vim.log.levels.WARN)
        return
      end
      if choice == "Merge when pipeline succeeds" then
        actions.merge(mr, { auto_merge = true })
      else
        actions.merge(mr)
      end
    end)
  end, map_opts)
  vim.keymap.set("n", "R", function()
    vim.api.nvim_win_close(win, true)
    M.open(mr_entry)
  end, map_opts)
end

return M
