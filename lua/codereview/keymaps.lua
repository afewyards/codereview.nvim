local M = {}

---@alias codereview.keymap.Key string|false

---@class codereview.config.Keymap
---@field next_file? codereview.keymap.Key
---@field prev_file? codereview.keymap.Key
---@field next_commit? codereview.keymap.Key
---@field prev_commit? codereview.keymap.Key
---@field move_down? codereview.keymap.Key
---@field move_up? codereview.keymap.Key
---@field select_next_note? codereview.keymap.Key
---@field select_prev_note? codereview.keymap.Key
---@field create_comment? codereview.keymap.Key
---@field create_range_comment? codereview.keymap.Key
---@field accept_suggestion? codereview.keymap.Key
---@field dismiss_suggestion? codereview.keymap.Key
---@field edit_suggestion? codereview.keymap.Key
---@field reply? codereview.keymap.Key
---@field edit_note? codereview.keymap.Key
---@field delete_note? codereview.keymap.Key
---@field react? codereview.keymap.Key
---@field toggle_resolve? codereview.keymap.Key
---@field toggle_full_file? codereview.keymap.Key
---@field dismiss_all_suggestions? codereview.keymap.Key
---@field submit? codereview.keymap.Key
---@field approve? codereview.keymap.Key
---@field refresh? codereview.keymap.Key
---@field quit? codereview.keymap.Key
---@field open_in_browser? codereview.keymap.Key
---@field merge? codereview.keymap.Key
---@field show_pipeline? codereview.keymap.Key
---@field ai_review? codereview.keymap.Key
---@field ai_review_file? codereview.keymap.Key
---@field pick_comments? codereview.keymap.Key
---@field pick_files? codereview.keymap.Key
---@field pick_commits? codereview.keymap.Key

local defaults = {
  next_file = { key = "]f", mode = "n", desc = "Next file" },
  prev_file = { key = "[f", mode = "n", desc = "Previous file" },
  next_commit = { key = "]c", mode = "n", desc = "Next commit" },
  prev_commit = { key = "[c", mode = "n", desc = "Previous commit" },
  move_down = { key = "j", mode = "n", desc = "Move down / next comment" },
  move_up = { key = "k", mode = "n", desc = "Move up / prev comment" },
  select_next_note = { key = "<Tab>", mode = "n", desc = "Select next note" },
  select_prev_note = { key = "<S-Tab>", mode = "n", desc = "Select prev note" },

  create_comment = { key = "cc", mode = "n", desc = "New comment" },
  create_range_comment = { key = "cc", mode = "v", desc = "Range comment" },

  accept_suggestion = { key = "a", mode = "n", desc = "Accept AI suggestion" },
  dismiss_suggestion = { key = "x", mode = "n", desc = "Dismiss suggestion" },
  edit_suggestion = { key = "e", mode = "n", desc = "Edit suggestion" },
  reply = { key = "r", mode = "n", desc = "Reply to thread" },
  edit_note = { key = "e", mode = "n", desc = "Edit note" },
  delete_note = { key = "x", mode = "n", desc = "Delete note" },
  react = { key = "rr", mode = "n", desc = "React to note" },

  toggle_resolve = { key = "R", mode = "n", desc = "Toggle resolve" },
  toggle_full_file = { key = "<C-f>", mode = "n", desc = "Full file view" },

  dismiss_all_suggestions = { key = "ds", mode = "n", desc = "Dismiss all" },
  submit = { key = "<C-s>", mode = "n", desc = "Submit drafts" },
  approve = { key = "<C-a>", mode = "n", desc = "Approve" },
  refresh = { key = "<C-r>", mode = "n", desc = "Refresh" },
  quit = { key = "<C-q>", mode = "n", desc = "Quit" },
  open_in_browser = { key = "o", mode = "n", desc = "Open in browser" },
  merge = { key = "M", mode = "n", desc = "Merge" },
  show_pipeline = { key = "p", mode = "n", desc = "Pipeline" },
  ai_review = { key = "A", mode = "n", desc = "Start/cancel AI" },
  ai_review_file = { key = "af", mode = "n", desc = "AI review current file" },
  pick_comments = { key = "<leader>fc", mode = "n", desc = "Pick comment/suggestion" },
  pick_files = { key = "<leader>ff", mode = "n", desc = "Pick file" },
  pick_commits = { key = "C", mode = "n", desc = "Pick commit" },
}

local function deep_copy(orig)
  local copy = {}
  for k, v in pairs(orig) do
    copy[k] = type(v) == "table" and deep_copy(v) or v
  end
  return copy
end

local resolved = nil

---@param user_opts? codereview.config.Keymap
function M.setup(user_opts)
  resolved = deep_copy(defaults)
  if not user_opts then
    return
  end
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
  if not resolved then
    M.setup()
  end
  local entry = resolved[action]
  return entry and entry.key
end

function M.get_all()
  if not resolved then
    M.setup()
  end
  return deep_copy(resolved)
end

function M.apply(buf, callbacks)
  if not resolved then
    M.setup()
  end
  local opts = { noremap = true, silent = true, nowait = true }

  -- Group by mode+key to detect collisions
  local groups = {}
  for action, fn in pairs(callbacks) do
    local entry = resolved[action]
    if entry and entry.key and entry.key ~= false then
      local k = entry.mode .. "\0" .. entry.key
      if not groups[k] then
        groups[k] = { entry = entry, fns = {} }
      end
      table.insert(groups[k].fns, fn)
    end
  end

  for _, g in pairs(groups) do
    local handler
    if #g.fns == 1 then
      handler = g.fns[1]
    else
      handler = function()
        for _, fn in ipairs(g.fns) do
          fn()
        end
      end
    end
    vim.keymap.set(
      g.entry.mode,
      g.entry.key,
      handler,
      vim.tbl_extend("force", opts, { buffer = buf, desc = g.entry.desc })
    )
  end
end

function M.reset()
  resolved = nil
end

return M
