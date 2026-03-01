local M = {}

local function make_previewer(lookup, get_text, ft)
  local builtin = require("fzf-lua.previewer.builtin")
  local Previewer = builtin.base:extend()

  function Previewer:new(o, opts, fzf_win)
    Previewer.super.new(self, o, opts, fzf_win)
    setmetatable(self, Previewer)
    return self
  end

  function Previewer:populate_preview_buf(entry_str)
    if not self.win or not self.win:validate_preview() then return end
    local tmpbuf = self:get_tmp_buffer()
    local entry = lookup[entry_str]
    local text = entry and get_text(entry) or "(no preview)"
    vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, vim.split(text, "\n", { plain = true }))
    vim.bo[tmpbuf].filetype = ft
    self:set_preview_buf(tmpbuf)
  end

  return Previewer
end

local function format_comment_preview(entry)
  if entry.type == "ai_suggestion" and entry.suggestion then
    local s = entry.suggestion
    local lines = { "[" .. s.severity .. "] " .. (s.file or "") .. ":" .. (s.line or ""), "" }
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
      table.insert(parts, "@" .. (note.author or "unknown") .. ":")
      table.insert(parts, note.body or "")
      table.insert(parts, "")
    end
    return table.concat(parts, "\n")
  end

  return "(no preview)"
end

function M.pick_mr(entries, on_select)
  local fzf = require("fzf-lua")

  local display_to_entry = {}
  local display_list = {}
  for _, entry in ipairs(entries) do
    table.insert(display_list, entry.display)
    display_to_entry[entry.display] = entry
  end

  fzf.fzf_exec(display_list, {
    prompt = "Reviews> ",
    previewer = make_previewer(display_to_entry, function(entry)
      local desc = entry.review and entry.review.description or ""
      return desc ~= "" and desc or "(no description)"
    end, "markdown"),
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local entry = display_to_entry[selected[1]]
          if entry then
            on_select(entry)
          end
        end
      end,
    },
  })
end

function M.pick_files(entries, on_select)
  local fzf = require("fzf-lua")
  local display_to_entry = {}
  local display_list = {}
  for _, entry in ipairs(entries) do
    table.insert(display_list, entry.display)
    display_to_entry[entry.display] = entry
  end

  fzf.fzf_exec(display_list, {
    prompt = "Files> ",
    previewer = make_previewer(display_to_entry, function(entry)
      return entry.diff or "(no diff available)"
    end, "diff"),
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local entry = display_to_entry[selected[1]]
          if entry then on_select(entry) end
        end
      end,
    },
  })
end

function M.pick_comments(entries, on_select, _opts)
  local fzf = require("fzf-lua")
  local display_to_entry = {}
  local display_list = {}
  for _, entry in ipairs(entries) do
    table.insert(display_list, entry.display)
    display_to_entry[entry.display] = entry
  end

  fzf.fzf_exec(display_list, {
    prompt = "Comments> ",
    previewer = make_previewer(display_to_entry, format_comment_preview, "markdown"),
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local entry = display_to_entry[selected[1]]
          if entry then on_select(entry) end
        end
      end,
      ["ctrl-r"] = function()
        vim.notify("Use search to filter comments", vim.log.levels.INFO)
      end,
    },
  })
end

function M.pick_branches(branches, on_select)
  local fzf = require("fzf-lua")
  fzf.fzf_exec(branches, {
    prompt = "Target branch> ",
    previewer = false,
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          on_select(selected[1])
        end
      end,
    },
  })
end

return M
