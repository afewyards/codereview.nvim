local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local markdown = require("glab_review.ui.markdown")
local detail = require("glab_review.mr.detail")
local M = {}

function M.build_thread_lines(disc)
  local lines = {}
  local notes = disc.notes or {}
  if #notes == 0 then return lines end

  local first = notes[1]

  -- Resolved status header
  local resolved_str = ""
  if first.resolvable then
    if first.resolved then
      local by = first.resolved_by and first.resolved_by.username or "?"
      resolved_str = "  [Resolved by @" .. by .. "]"
    else
      resolved_str = "  [Unresolved]"
    end
  end

  table.insert(lines, string.format(
    "@%s (%s)%s",
    first.author.username,
    detail.format_time(first.created_at),
    resolved_str
  ))

  for _, body_line in ipairs(markdown.to_lines(first.body)) do
    table.insert(lines, "  " .. body_line)
  end

  -- Replies
  for i = 2, #notes do
    local reply = notes[i]
    table.insert(lines, "")
    table.insert(lines, string.format(
      "  -> @%s (%s):",
      reply.author.username,
      detail.format_time(reply.created_at)
    ))
    for _, body_line in ipairs(markdown.to_lines(reply.body)) do
      table.insert(lines, "     " .. body_line)
    end
  end

  return lines
end

function M.show_thread(disc, mr)
  local thread_lines = M.build_thread_lines(disc)

  local hints = {
    "",
    "[r] reply  [R] un/resolve  [o] open browser  [q] close",
  }

  local all_lines = {}
  for _, l in ipairs(thread_lines) do table.insert(all_lines, l) end
  for _, l in ipairs(hints) do table.insert(all_lines, l) end

  local width = 70
  local height = math.min(#all_lines + 2, 30)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  markdown.set_buf_markdown(buf)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Thread ",
    title_pos = "center",
  })

  local close = function() pcall(vim.api.nvim_win_close, win, true) end
  local map_opts = { buffer = buf, nowait = true }

  vim.keymap.set("n", "q", close, map_opts)
  vim.keymap.set("n", "r", function()
    close()
    M.reply(disc, mr)
  end, map_opts)
  vim.keymap.set("n", "R", function()
    close()
    M.resolve_toggle(disc, mr, function()
      vim.notify("Resolve status toggled", vim.log.levels.INFO)
    end)
  end, map_opts)
  vim.keymap.set("n", "o", function()
    if mr and mr.web_url then
      vim.ui.open(mr.web_url)
    end
  end, map_opts)
end

function M.reply(disc, mr)
  vim.ui.input({ prompt = "Reply: " }, function(input)
    if not input or input == "" then return end
    local base_url, project = git.detect_project()
    if not base_url or not project then
      vim.notify("Could not detect GitLab project", vim.log.levels.ERROR)
      return
    end
    local encoded = client.encode_project(project)
    local _, err = client.post(base_url, endpoints.discussion_notes(encoded, mr.iid, disc.id), {
      body = { body = input },
    })
    if err then
      vim.notify("Failed to post reply: " .. err, vim.log.levels.ERROR)
    else
      vim.notify("Reply posted", vim.log.levels.INFO)
    end
  end)
end

function M.resolve_toggle(disc, mr, callback)
  local first = disc.notes and disc.notes[1]
  if not first then return end

  local base_url, project = git.detect_project()
  if not base_url or not project then
    vim.notify("Could not detect GitLab project", vim.log.levels.ERROR)
    return
  end
  local encoded = client.encode_project(project)
  local currently_resolved = first.resolved
  local _, err = client.put(base_url, endpoints.discussion(encoded, mr.iid, disc.id), {
    body = { resolved = not currently_resolved },
  })
  if err then
    vim.notify("Failed to toggle resolve: " .. err, vim.log.levels.ERROR)
  elseif callback then
    callback()
  end
end

function M.create_inline(mr, old_path, new_path, old_line, new_line)
  vim.ui.input({ prompt = "Inline comment: " }, function(input)
    if not input or input == "" then return end
    local base_url, project = git.detect_project()
    if not base_url or not project then
      vim.notify("Could not detect GitLab project", vim.log.levels.ERROR)
      return
    end
    local encoded = client.encode_project(project)
    local _, err = client.post(base_url, endpoints.discussions(encoded, mr.iid), {
      body = {
        body = input,
        position = {
          position_type = "text",
          base_sha = mr.diff_refs and mr.diff_refs.base_sha,
          head_sha = mr.diff_refs and mr.diff_refs.head_sha,
          start_sha = mr.diff_refs and mr.diff_refs.start_sha,
          old_path = old_path,
          new_path = new_path,
          old_line = old_line,
          new_line = new_line,
        },
      },
    })
    if err then
      vim.notify("Failed to post comment: " .. err, vim.log.levels.ERROR)
    else
      vim.notify("Comment posted", vim.log.levels.INFO)
    end
  end)
end

function M.create_inline_range(mr, old_path, new_path, start_pos, end_pos)
  vim.ui.input({ prompt = "Range comment: " }, function(input)
    if not input or input == "" then return end
    local base_url, project = git.detect_project()
    if not base_url or not project then
      vim.notify("Could not detect GitLab project", vim.log.levels.ERROR)
      return
    end
    local encoded = client.encode_project(project)
    local _, err = client.post(base_url, endpoints.discussions(encoded, mr.iid), {
      body = {
        body = input,
        position = {
          position_type = "text",
          base_sha = mr.diff_refs and mr.diff_refs.base_sha,
          head_sha = mr.diff_refs and mr.diff_refs.head_sha,
          start_sha = mr.diff_refs and mr.diff_refs.start_sha,
          old_path = old_path,
          new_path = new_path,
          line_range = {
            start = {
              line_code = nil,
              type = start_pos.type or "new",
              old_line = start_pos.old_line,
              new_line = start_pos.new_line,
            },
            ["end"] = {
              line_code = nil,
              type = end_pos.type or "new",
              old_line = end_pos.old_line,
              new_line = end_pos.new_line,
            },
          },
        },
      },
    })
    if err then
      vim.notify("Failed to post range comment: " .. err, vim.log.levels.ERROR)
    else
      vim.notify("Range comment posted", vim.log.levels.INFO)
    end
  end)
end

return M
