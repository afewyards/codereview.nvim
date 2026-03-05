local M = {}

function M.pick_mr(entries, on_select)
  local snacks = require("snacks")

  local items = {}
  for _, entry in ipairs(entries) do
    local desc = entry.review and entry.review.description or ""
    table.insert(items, {
      text = entry.display,
      data = entry,
      preview = {
        text = "# "
          .. entry.title
          .. "\n\n"
          .. "**Branch:** "
          .. entry.source_branch
          .. "  \n"
          .. "**Updated:** "
          .. entry.time_str
          .. "\n\n"
          .. (desc ~= "" and desc or "(no description)"),
        ft = "markdown",
      },
    })
  end

  local max_title, max_author, max_id, max_len = 0, 0, 0, 0
  for _, e in ipairs(entries) do
    max_title = math.max(max_title, #e.title_display)
    max_author = math.max(max_author, #e.author)
    max_id = math.max(max_id, #tostring(e.id))
  end
  for _, e in ipairs(entries) do
    max_len = math.max(max_len, vim.api.nvim_strwidth(e.display))
  end
  local width = math.min(max_len + 3, math.floor(vim.o.columns * 0.9))

  snacks.picker({
    title = "Code Reviews",
    items = items,
    layout = {
      layout = {
        width = width,
        height = 0.8,
        box = "vertical",
        border = true,
        title = "{title} {live} {flags}",
        title_pos = "center",
        { win = "input", height = 1, border = "bottom" },
        { win = "list", border = "none" },
        { win = "preview", title = "{preview}", height = 0.7, border = "top" },
      },
    },
    list = { gap = 0, separator = false },
    preview = "preview",
    format = function(item)
      local e = item.data
      local unread = e.unread and "* " or "  "
      local title_fmt = "%-" .. max_title .. "s"
      local author_fmt = "%-" .. max_author .. "s"
      local id_fmt = "%-" .. max_id .. "d"
      return {
        { unread, e.unread and "DiagnosticWarn" or "" },
        { e.pipeline_icon .. " ", "Comment" },
        { "#" .. string.format(id_fmt, e.id) .. " ", "Special" },
        { string.format(title_fmt, e.title_display) .. "  " },
        { "@" .. string.format(author_fmt, e.author) .. "  ", "Comment" },
        { e.time_str, "Comment" },
      }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        on_select(item.data)
      end
    end,
  })
end

function M.pick_files(entries, on_select)
  local snacks = require("snacks")
  local items = {}
  for _, entry in ipairs(entries) do
    table.insert(items, {
      text = entry.display,
      data = entry,
      preview = {
        text = entry.diff or "(no diff available)",
        ft = "diff",
      },
    })
  end

  snacks.picker({
    title = "Review Files",
    items = items,
    preview = "preview",
    format = function(item)
      return { { item.text } }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        on_select(item.data)
      end
    end,
  })
end

local function format_comment_preview(entry)
  if entry.type == "ai_suggestion" and entry.suggestion then
    local s = entry.suggestion
    local lines = { "**[" .. s.severity .. "]** " .. (s.file or "") .. ":" .. (s.line or ""), "" }
    if s.code then
      table.insert(lines, "```")
      table.insert(lines, s.code)
      table.insert(lines, "```")
      table.insert(lines, "")
    end
    table.insert(lines, s.comment or "")
    return table.concat(lines, "\n")
  end

  if entry.type == "discussion" and entry.discussion then
    local parts = {}
    for _, note in ipairs(entry.discussion.notes or {}) do
      table.insert(parts, "**@" .. (note.author or "unknown") .. ":**")
      table.insert(parts, note.body or "")
      table.insert(parts, "")
    end
    return table.concat(parts, "\n")
  end

  return "(no preview)"
end

function M.pick_comments(entries, on_select, _opts)
  local snacks = require("snacks")
  local items = {}
  for _, entry in ipairs(entries) do
    table.insert(items, {
      text = entry.display,
      data = entry,
      preview = {
        text = format_comment_preview(entry),
        ft = "markdown",
      },
    })
  end

  snacks.picker({
    title = "Comments & Suggestions",
    items = items,
    preview = "preview",
    format = function(item)
      return { { item.text } }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        on_select(item.data)
      end
    end,
  })
end

function M.pick_commits(entries, on_select, opts)
  local snacks = require("snacks")
  local items = {}
  for _, entry in ipairs(entries) do
    table.insert(items, { text = entry.display, data = entry })
  end

  local default_idx = opts and opts.default_selection_index or 1

  snacks.picker({
    title = "Commits",
    items = items,
    layout = { preset = "select", preview = false },
    on_show = function(picker)
      if default_idx > 1 then
        picker.list:view(default_idx)
      end
    end,
    format = function(item)
      local entry = item.data
      if entry and entry.type == "commit" and entry.additions then
        local short = (entry.sha or ""):sub(1, 8)
        return {
          { "  " },
          { short .. " ", "Special" },
          { (entry.title or "") .. "  " },
          { string.format("+%d", entry.additions), "diffAdded" },
          { " " },
          { string.format("-%d", entry.deletions), "diffRemoved" },
          { string.format("  (%s)", entry.author or "") },
        }
      end
      return { { item.text } }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        on_select(item.data)
      end
    end,
  })
end

function M.pick_branches(branches, on_select)
  local snacks = require("snacks")
  local items = {}
  for _, branch in ipairs(branches) do
    table.insert(items, { text = branch })
  end

  snacks.picker({
    title = "Target Branch",
    items = items,
    layout = { preset = "select", preview = false },
    format = function(item)
      return { { item.text } }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        on_select(item.text)
      end
    end,
  })
end

return M
