local M = {}

local GITLAB_ITEMS = {
  { type = "checkbox", key = "squash", label = "Squash commits", checked = false },
  { type = "checkbox", key = "remove_source_branch", label = "Delete source branch", checked = false },
  { type = "checkbox", key = "auto_merge", label = "Merge when pipeline succeeds", checked = false },
}

local GITHUB_ITEMS = {
  { type = "cycle", key = "merge_method", label = "Method", values = { "merge", "squash", "rebase" }, idx = 1 },
  { type = "checkbox", key = "remove_source_branch", label = "Delete source branch", checked = false },
}

--- Build item list for the given platform.
--- @param platform string "gitlab"|"github"
--- @return table[]
function M.build_items(platform)
  local template = platform == "github" and GITHUB_ITEMS or GITLAB_ITEMS
  local items = {}
  for _, t in ipairs(template) do
    local item = {}
    for k, v in pairs(t) do item[k] = v end
    if item.values then
      local vals = {}
      for _, v in ipairs(item.values) do vals[#vals + 1] = v end
      item.values = vals
    end
    items[#items + 1] = item
  end
  return items
end

--- Render a single item as a display line.
--- @param item table
--- @return string
function M.render_line(item)
  if item.type == "checkbox" then
    local mark = item.checked and "x" or " "
    return "  [" .. mark .. "] " .. item.label
  elseif item.type == "cycle" then
    return "  " .. item.label .. ": ◀ " .. item.values[item.idx] .. " ▶"
  end
  return ""
end

--- Collect current item states into an opts table for actions.merge().
--- @param items table[]
--- @return table
function M.collect_opts(items)
  local opts = {}
  for _, item in ipairs(items) do
    if item.type == "checkbox" then
      if item.checked then opts[item.key] = true end
    elseif item.type == "cycle" then
      opts[item.key] = item.values[item.idx]
    end
  end
  return opts
end

--- Render all buffer lines: blank, items, blank, button, blank.
--- @param items table[]
--- @return string[]
local function render_buf(items)
  local lines = { "" }
  for _, item in ipairs(items) do
    lines[#lines + 1] = M.render_line(item)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "          [ Merge ]"
  lines[#lines + 1] = ""
  return lines
end

--- Open the merge float.
--- @param review table  The review/MR object (must have .id)
--- @param platform string  "gitlab"|"github"
--- @param on_merge? fun(opts: table)  Called with collected opts on confirm (default: actions.merge)
function M.open(review, platform, on_merge)
  local ifloat = require("codereview.ui.inline_float")
  local items = M.build_items(platform)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  -- First item line is at buffer line 2 (1-indexed); last at 2 + #items - 1
  local first_item_line = 2
  local last_item_line = first_item_line + #items - 1

  local function redraw()
    vim.bo[buf].modifiable = true
    local lines = render_buf(items)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end

  redraw()

  local height = #items + 4  -- blank + items + blank + button + blank
  local width = 40
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local label = platform == "github" and "PR" or "MR"
  local title = ifloat.title(string.format("Merge %s #%d", label, review.id))

  local footer_parts = { { " ", "CodeReviewFloatFooterText" } }
  if platform == "github" then
    table.insert(footer_parts, { "<Tab>", "CodeReviewFloatFooterKey" })
    table.insert(footer_parts, { " method  ", "CodeReviewFloatFooterText" })
  end
  table.insert(footer_parts, { "<Space>", "CodeReviewFloatFooterKey" })
  table.insert(footer_parts, { " toggle  ", "CodeReviewFloatFooterText" })
  table.insert(footer_parts, { "<CR>", "CodeReviewFloatFooterKey" })
  table.insert(footer_parts, { " merge ", "CodeReviewFloatFooterText" })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = ifloat.border(),
    title = title,
    title_pos = "center",
    footer = footer_parts,
    footer_pos = "center",
    noautocmd = true,
  })

  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_set_option_value("winhighlight", "NormalFloat:Normal,CursorLine:Visual", { win = win })
  pcall(vim.api.nvim_win_set_cursor, win, { first_item_line, 0 })

  local closed = false
  local function close()
    if closed then return end
    closed = true
    pcall(vim.api.nvim_win_close, win, true)
  end

  local function clamp_cursor()
    local pos = vim.api.nvim_win_get_cursor(win)
    local r = pos[1]
    if r < first_item_line then
      vim.api.nvim_win_set_cursor(win, { first_item_line, 0 })
    elseif r > last_item_line then
      vim.api.nvim_win_set_cursor(win, { last_item_line, 0 })
    end
  end

  local function get_item_idx()
    local r = vim.api.nvim_win_get_cursor(win)[1]
    return r - first_item_line + 1
  end

  local map_opts = { buffer = buf, nowait = true, silent = true }

  -- Navigation
  vim.keymap.set("n", "j", function()
    local r = vim.api.nvim_win_get_cursor(win)[1]
    if r < last_item_line then
      vim.api.nvim_win_set_cursor(win, { r + 1, 0 })
    end
  end, map_opts)

  vim.keymap.set("n", "k", function()
    local r = vim.api.nvim_win_get_cursor(win)[1]
    if r > first_item_line then
      vim.api.nvim_win_set_cursor(win, { r - 1, 0 })
    end
  end, map_opts)

  -- Toggle checkbox
  vim.keymap.set("n", "<Space>", function()
    local idx = get_item_idx()
    if idx >= 1 and idx <= #items and items[idx].type == "checkbox" then
      items[idx].checked = not items[idx].checked
      redraw()
      vim.api.nvim_win_set_cursor(win, { first_item_line + idx - 1, 0 })
    end
  end, map_opts)

  -- Cycle merge method (GitHub)
  vim.keymap.set("n", "<Tab>", function()
    local idx = get_item_idx()
    if idx >= 1 and idx <= #items and items[idx].type == "cycle" then
      items[idx].idx = (items[idx].idx % #items[idx].values) + 1
      redraw()
      vim.api.nvim_win_set_cursor(win, { first_item_line + idx - 1, 0 })
    end
  end, map_opts)

  vim.keymap.set("n", "<S-Tab>", function()
    local idx = get_item_idx()
    if idx >= 1 and idx <= #items and items[idx].type == "cycle" then
      items[idx].idx = ((items[idx].idx - 2) % #items[idx].values) + 1
      redraw()
      vim.api.nvim_win_set_cursor(win, { first_item_line + idx - 1, 0 })
    end
  end, map_opts)

  -- Confirm
  vim.keymap.set("n", "<CR>", function()
    local opts = M.collect_opts(items)
    close()
    if on_merge then
      on_merge(opts)
    else
      require("codereview.mr.actions").merge(review, opts)
    end
  end, map_opts)

  -- Cancel
  vim.keymap.set("n", "q", close, map_opts)
  vim.keymap.set("n", "<Esc>", close, map_opts)

  -- Clamp cursor on any movement
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      if closed then return true end
      clamp_cursor()
    end,
  })

  -- Auto-close on WinClosed
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() close() end,
  })

  return { buf = buf, win = win, close = close }
end

return M
