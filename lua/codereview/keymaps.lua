local M = {}

local defaults = {
  next_file            = { key = "]f",    mode = "n", desc = "Next file" },
  prev_file            = { key = "[f",    mode = "n", desc = "Previous file" },
  next_comment         = { key = "]c",    mode = "n", desc = "Next comment" },
  prev_comment         = { key = "[c",    mode = "n", desc = "Previous comment" },
  next_suggestion      = { key = "]s",    mode = "n", desc = "Next AI suggestion" },
  prev_suggestion      = { key = "[s",    mode = "n", desc = "Previous AI suggestion" },
  create_comment       = { key = "cc",    mode = "n", desc = "New comment" },
  create_range_comment = { key = "cc",    mode = "v", desc = "Range comment" },
  reply                = { key = "r",     mode = "n", desc = "Reply to thread" },
  toggle_resolve       = { key = "gt",    mode = "n", desc = "Toggle resolve" },
  increase_context     = { key = "+",     mode = "n", desc = "More context" },
  decrease_context     = { key = "-",     mode = "n", desc = "Less context" },
  toggle_full_file     = { key = "<C-f>", mode = "n", desc = "Full file view" },
  toggle_scroll_mode   = { key = "<C-a>", mode = "n", desc = "Scroll/per-file toggle" },
  accept_suggestion    = { key = "a",     mode = "n", desc = "Accept AI suggestion" },
  dismiss_suggestion   = { key = "x",     mode = "n", desc = "Dismiss suggestion" },
  edit_suggestion      = { key = "e",     mode = "n", desc = "Edit suggestion" },
  dismiss_all_suggestions = { key = "ds", mode = "n", desc = "Dismiss all" },
  submit               = { key = "S",     mode = "n", desc = "Submit drafts" },
  approve              = { key = "a",     mode = "n", desc = "Approve" },
  open_in_browser      = { key = "o",     mode = "n", desc = "Open in browser" },
  merge                = { key = "m",     mode = "n", desc = "Merge" },
  show_pipeline        = { key = "p",     mode = "n", desc = "Pipeline" },
  ai_review            = { key = "A",     mode = "n", desc = "Start/cancel AI" },
  refresh              = { key = "R",     mode = "n", desc = "Refresh" },
  quit                 = { key = "Q",     mode = "n", desc = "Quit" },
}

local function deep_copy(orig)
  local copy = {}
  for k, v in pairs(orig) do
    copy[k] = type(v) == "table" and deep_copy(v) or v
  end
  return copy
end

local resolved = nil

function M.setup(user_opts)
  resolved = deep_copy(defaults)
  if not user_opts then return end
  for action, value in pairs(user_opts) do
    if not defaults[action] then
      if vim and vim.notify then
        local level = vim.log and vim.log.levels and vim.log.levels.WARN or 2
        vim.notify(string.format("[codereview] Unknown keymap action: %q", action), level)
      end
    elseif value == false then
      resolved[action].key = false
    elseif type(value) == "string" then
      resolved[action].key = value
    end
  end
end

function M.get(action)
  if not resolved then M.setup() end
  local entry = resolved[action]
  return entry and entry.key
end

function M.get_all()
  if not resolved then M.setup() end
  return deep_copy(resolved)
end

function M.apply(buf, callbacks)
  if not resolved then M.setup() end
  local opts = { noremap = true, silent = true, nowait = true }
  local actions = {}
  for action in pairs(callbacks) do table.insert(actions, action) end
  table.sort(actions)
  for _, action in ipairs(actions) do
    local fn = callbacks[action]
    local entry = resolved[action]
    if entry and entry.key and entry.key ~= false then
      vim.keymap.set(entry.mode, entry.key, fn, vim.tbl_extend("force", opts, { buffer = buf, desc = entry.desc }))
    end
  end
end

function M.reset()
  resolved = nil
end

return M
