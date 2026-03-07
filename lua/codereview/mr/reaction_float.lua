--- Reaction picker float — shows all 8 emojis, lets user toggle reactions.
local M = {}

local reactions_mod = require("codereview.reactions")
local NS = vim.api.nvim_create_namespace("codereview_reaction_float")

--- Parse note.reactions into an array indexed by EMOJIS order.
--- @param note_reactions table|nil  Array of { name, count, reacted }
--- @return table[]  Array of { count, reacted }
local function parse_reactions(note_reactions)
  local by_name = {}
  for _, r in ipairs(note_reactions or {}) do
    by_name[r.name] = r
  end
  local result = {}
  for _, emoji in ipairs(reactions_mod.EMOJIS) do
    local r = by_name[emoji.name] or {}
    table.insert(result, { count = r.count or 0, reacted = r.reacted or false })
  end
  return result
end

--- Build virtual text chunks for the emoji row.
--- @param reactions table[]  Indexed by emoji order
--- @param selected number    Currently selected index
--- @return table[] chunks  Array of { text, hl } for virt_text
--- @return number width    Display width of the line
local function build_virt_chunks(reactions, selected)
  local chunks = { { "  ", "" } }
  for i, emoji in ipairs(reactions_mod.EMOJIS) do
    local r = reactions[i]
    if i > 1 then
      table.insert(chunks, { "  ", "" })
    end
    local hl
    if i == selected then
      hl = "CodeReviewReactionSelected"
    elseif r.reacted then
      hl = "CodeReviewReactionOwn"
    elseif r.count > 0 then
      hl = "CodeReviewReaction"
    else
      hl = ""
    end
    local text = emoji.icon
    if r.count > 1 then
      text = text .. " " .. tostring(r.count)
    end
    table.insert(chunks, { text, hl })
  end
  table.insert(chunks, { "  ", "" })
  local width = 0
  for _, c in ipairs(chunks) do
    width = width + vim.fn.strdisplaywidth(c[1])
  end
  return chunks, width
end

--- Render virtual text on the empty buffer line.
local function render(buf, reactions, selected)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  local chunks, _ = build_virt_chunks(reactions, selected)
  vim.api.nvim_buf_set_extmark(buf, NS, 0, 0, {
    virt_text = chunks,
    virt_text_pos = "overlay",
  })
end

--- Open the reaction picker float.
--- @param note table  The note; note.reactions may be nil or {}
--- @param opts table  { on_toggle: function(emoji_name, reacted) }
---   on_toggle(emoji_name, reacted): emoji_name is normalized (e.g. "thumbsup"),
---   reacted is true when adding, false when removing.
--- @return table  { close: function }
function M.open(note, opts)
  opts = opts or {}

  local reactions = parse_reactions(note.reactions)
  local selected = 1
  local closed = false

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false

  local _, width = build_virt_chunks(reactions, selected)
  render(buf, reactions, selected)
  local border_hl = "CodeReviewCommentBorder"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = 1,
    style = "minimal",
    border = {
      { "╭", border_hl },
      { "─", border_hl },
      { "╮", border_hl },
      { "│", border_hl },
      { "╯", border_hl },
      { "─", border_hl },
      { "╰", border_hl },
      { "│", border_hl },
    },
    noautocmd = true,
  })

  vim.api.nvim_set_option_value("winblend", 0, { win = win })
  vim.api.nvim_set_option_value("winhighlight", "NormalFloat:Normal", { win = win })

  local function close()
    if closed then
      return
    end
    closed = true
    pcall(vim.api.nvim_win_close, win, true)
  end

  local function re_render()
    if closed then
      return
    end
    render(buf, reactions, selected)
  end

  local function toggle(idx)
    if closed then
      return
    end
    local emoji = reactions_mod.EMOJIS[idx]
    if not emoji then
      return
    end
    local r = reactions[idx]
    local new_reacted = not r.reacted
    r.reacted = new_reacted
    r.count = math.max(0, r.count + (new_reacted and 1 or -1))
    re_render()
    if opts.on_toggle then
      opts.on_toggle(emoji.name, new_reacted)
    end
  end

  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end

  local function move_left()
    selected = math.max(1, selected - 1)
    re_render()
  end

  local function move_right()
    selected = math.min(#reactions_mod.EMOJIS, selected + 1)
    re_render()
  end

  map("h", move_left)
  map("l", move_right)
  map("<Tab>", move_right)
  map("<S-Tab>", move_left)

  map("<CR>", function()
    toggle(selected)
  end)

  map("q", close)
  map("<Esc>", close)

  for i = 1, 8 do
    local idx = i
    map(tostring(idx), function()
      selected = idx
      toggle(idx)
    end)
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      close()
    end,
  })

  return { close = close }
end

return M
