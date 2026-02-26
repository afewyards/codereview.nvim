-- lua/codereview/mr/sidebar_help.lua
-- Keybinding reference help float for the diff sidebar.

local M = {}

--- Convert Vim keybinding notation to human-readable Unicode symbols.
--- E.g., "<C-f>" -> "⌃F", "<leader>ff" -> "<leader>ff" (unchanged)
local function format_key(key)
  if not key then
    return "(disabled)"
  end

  -- Convert common Ctrl combinations to Unicode symbols
  local replacements = {
    ["<C%-a>"] = "⌃A",
    ["<C%-f>"] = "⌃F",
    ["<C%-d>"] = "⌃D",
    ["<C%-e>"] = "⌃E",
  }

  for pattern, replacement in pairs(replacements) do
    if key:match("^" .. pattern .. "$") then
      return replacement
    end
  end

  return key
end

--- Build the help text as an array of strings.
--- Groups keybindings into Navigation, Review, and General sections.
function M.build_lines()
  local km = require("codereview.keymaps")
  local lines = {}

  -- Action definitions with descriptions and section assignment
  local actions = {
    navigation = {
      { action = "next_file", desc = "Next file" },
      { action = "prev_file", desc = "Previous file" },
      { action = "toggle_full_file", desc = "Toggle full file" },
      { action = "toggle_scroll_mode", desc = "Toggle scroll mode" },
    },
    review = {
      { action = "create_comment", desc = "New comment" },
      { action = "create_range_comment", desc = "Range comment" },
      { action = "reply", desc = "Reply" },
      { action = "toggle_resolve", desc = "Toggle resolve" },
      { action = "accept_suggestion", desc = "Accept suggestion" },
      { action = "dismiss_suggestion", desc = "Dismiss suggestion" },
      { action = "submit", desc = "Submit review" },
      { action = "approve", desc = "Approve" },
    },
    general = {
      { action = "open_in_browser", desc = "Open in browser" },
      { action = "ai_review", desc = "AI review" },
      { action = "refresh", desc = "Refresh" },
      { action = "quit", desc = "Quit" },
      { action = "pick_files", desc = "Pick files" },
    },
  }

  -- Helper to add a section
  local function add_section(title, section_actions)
    table.insert(lines, "")
    table.insert(lines, "  " .. title)
    table.insert(lines, "  " .. string.rep("─", #title))

    for _, item in ipairs(section_actions) do
      local key = km.get(item.action)
      local formatted_key = format_key(key)
      table.insert(lines, string.format("    %-20s %s", formatted_key, item.desc))
    end
  end

  -- Header
  table.insert(lines, "")
  table.insert(lines, "  Help")
  table.insert(lines, "  ────")

  -- Sections
  add_section("Navigation", actions.navigation)
  add_section("Review", actions.review)
  add_section("General", actions.general)

  table.insert(lines, "")
  table.insert(lines, "  q or Esc to close")
  table.insert(lines, "")

  return lines
end

--- Open a floating window displaying help content.
--- Returns { buf = buf_handle, win = win_handle }
function M.open()
  -- Create a new buffer
  local buf = vim.api.nvim_create_buf(false, true)

  -- Set buffer options
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true

  -- Get help content
  local lines = M.build_lines()

  -- Set buffer content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Make buffer read-only
  vim.bo[buf].modifiable = false

  -- Create floating window configuration
  local width = 60
  local height = 20
  local lines = tonumber(vim.o.lines) or 24
  local columns = tonumber(vim.o.columns) or 80
  local win_cfg = {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((lines - height) / 2),
    col = math.floor((columns - width) / 2),
    style = "minimal",
    border = "rounded",
  }

  -- Open the window
  local win = vim.api.nvim_open_win(buf, true, win_cfg)

  -- Set window options
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = false

  -- Set keymaps to close the float
  local function close_float()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "q", close_float, { buffer = buf, noremap = true, silent = true })
  vim.keymap.set("n", "<Esc>", close_float, { buffer = buf, noremap = true, silent = true })

  return { buf = buf, win = win }
end

return M
