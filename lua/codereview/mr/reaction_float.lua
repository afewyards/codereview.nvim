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

--- Build the display line and byte-range segments for each emoji slot.
--- @param reactions table[]  Indexed by emoji order
--- @return string line, table[] segments
local function build_content(reactions)
  local parts = {}
  local segments = {}
  local byte_pos = 2 -- after leading '  '

  for i, emoji in ipairs(reactions_mod.EMOJIS) do
    local r = reactions[i]
    local sep = i == 1 and "" or "  "
    byte_pos = byte_pos + #sep

    local seg_start = byte_pos
    local text = emoji.icon
    if r.count > 1 then
      text = text .. " " .. tostring(r.count)
    end
    table.insert(parts, sep .. text)
    byte_pos = byte_pos + #text

    table.insert(segments, { start_byte = seg_start, end_byte = byte_pos, index = i })
  end

  return "  " .. table.concat(parts) .. "  ", segments
end

--- Apply extmark highlights to the single content line.
local function apply_highlights(buf, segments, reactions, selected)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for i, seg in ipairs(segments) do
    local r = reactions[i]
    local hl
    if i == selected then
      hl = "CodeReviewReactionSelected"
    elseif r.reacted then
      hl = "CodeReviewReactionOwn"
    elseif r.count > 0 then
      hl = "CodeReviewReaction"
    end
    if hl then
      vim.api.nvim_buf_set_extmark(buf, NS, 0, seg.start_byte, {
        end_col = seg.end_byte,
        hl_group = hl,
      })
    end
  end
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

  local line, segments = build_content(reactions)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  apply_highlights(buf, segments, reactions, selected)
  vim.bo[buf].modifiable = false

  local width = vim.fn.strdisplaywidth(line)
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
  vim.api.nvim_set_option_value("winhighlight", "NormalFloat:Normal,Cursor:CodeReviewReactionSelected", { win = win })

  -- Place cursor on the first emoji (skip leading padding)
  pcall(vim.api.nvim_win_set_cursor, win, { 1, segments[1].start_byte })

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
    vim.bo[buf].modifiable = true
    line, segments = build_content(reactions)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    apply_highlights(buf, segments, reactions, selected)
    vim.bo[buf].modifiable = false
    -- Move cursor to selected segment
    pcall(vim.api.nvim_win_set_cursor, win, { 1, segments[selected].start_byte })
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
    close()
  end)

  map("q", close)
  map("<Esc>", close)

  for i = 1, 8 do
    local idx = i
    map(tostring(idx), function()
      selected = idx
      toggle(idx)
      close()
    end)
  end

  -- Block visual mode and insert mode to prevent text selection/editing
  local noop = function() end
  map("v", noop)
  map("V", noop)
  map("<C-v>", noop)
  map("i", noop)
  map("a", noop)
  map("o", noop)
  map("I", noop)
  map("A", noop)
  map("O", noop)

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
