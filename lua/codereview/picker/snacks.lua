local M = {}

function M.pick_mr(entries, on_select)
  local snacks = require("snacks")

  local items = {}
  for _, entry in ipairs(entries) do
    table.insert(items, {
      text = entry.display,
      data = entry,
      preview = {
        text = require("codereview.mr.list").format_mr_preview(entry),
        ft = "markdown",
      },
    })
  end

  local w = entries[1] and entries[1]._col_widths or { title = 70, author = 0, id = 0, icon = 0 }
  local max_len = 0
  for _, e in ipairs(entries) do
    max_len = math.max(max_len, vim.api.nvim_strwidth(e.display))
  end
  local width = math.min((max_len + 6) / vim.o.columns, 0.8)

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
      return {
        { unread, e.unread and "DiagnosticWarn" or "" },
        { string.format("%-" .. w.icon .. "s", e.pipeline_icon) .. " ", "Comment" },
        { "#" .. string.format("%-" .. w.id .. "d", e.id) .. " ", "Special" },
        { string.format("%-" .. w.title .. "s", e.title_display) .. "  " },
        { "@" .. string.format("%-" .. w.author .. "s", e.author) .. "  ", "Comment" },
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

function M.pick_comments(entries, on_select, opts)
  local snacks = require("snacks")
  local comments_mod = require("codereview.picker.comments")

  local filters = { "all", "unresolved", "resolved" }
  local filter_idx = 1
  local current_entries = entries

  local function make_items(e)
    local items = {}
    for _, entry in ipairs(e) do
      table.insert(items, {
        text = entry.display,
        data = entry,
        preview = {
          text = comments_mod.format_preview(entry),
          ft = "markdown",
        },
      })
    end
    return items
  end

  snacks.picker({
    title = "Comments & Suggestions [all]",
    items = make_items(current_entries),
    preview = "preview",
    format = function(item)
      return { { item.text } }
    end,
    actions = {
      cycle_filter = function(picker)
        filter_idx = (filter_idx % #filters) + 1
        local filter = filters[filter_idx] == "all" and nil or filters[filter_idx]
        if opts and opts.rebuild then
          current_entries = opts.rebuild(filter)
        end
        picker.opts.items = make_items(current_entries)
        picker.title = "Comments & Suggestions [" .. filters[filter_idx] .. "]"
        picker:find({ refresh = true })
      end,
    },
    win = {
      input = {
        keys = {
          ["<C-r>"] = { "cycle_filter", mode = { "n", "i" }, desc = "Cycle filter" },
        },
      },
    },
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
