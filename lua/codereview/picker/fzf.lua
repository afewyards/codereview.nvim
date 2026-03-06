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
    if not self.win or not self.win:validate_preview() then
      return
    end
    local tmpbuf = self:get_tmp_buffer()
    local entry = lookup[entry_str]
    local text = entry and get_text(entry) or "(no preview)"
    vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, vim.split(text, "\n", { plain = true }))
    vim.bo[tmpbuf].filetype = ft
    self:set_preview_buf(tmpbuf)
  end

  return Previewer
end

function M.pick_mr(entries, on_select)
  local fzf = require("fzf-lua")

  local display_to_entry = {}
  local display_list = {}
  for _, entry in ipairs(entries) do
    table.insert(display_list, entry.display)
    display_to_entry[entry.display] = entry
  end

  local max_len = 0
  for _, d in ipairs(display_list) do
    max_len = math.max(max_len, vim.api.nvim_strwidth(d))
  end
  local max_cols = math.floor(vim.o.columns * 0.9)
  local width = math.min(max_len + 5, max_cols)

  fzf.fzf_exec(display_list, {
    prompt = "Reviews> ",
    winopts = { width = width, height = 0.8, preview = { layout = "vertical", vertical = "down:70%" } },
    previewer = make_previewer(display_to_entry, function(entry)
      local desc = entry.review and entry.review.description or ""
      return "# "
        .. entry.title
        .. "\n\n"
        .. "**Branch:** "
        .. (entry.source_branch or "")
        .. "  \n"
        .. "**Updated:** "
        .. (entry.time_str or "")
        .. "\n\n"
        .. (desc ~= "" and desc or "(no description)")
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
          if entry then
            on_select(entry)
          end
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
    previewer = make_previewer(display_to_entry, require("codereview.picker.comments").format_preview, "markdown"),
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local entry = display_to_entry[selected[1]]
          if entry then
            on_select(entry)
          end
        end
      end,
      ["ctrl-r"] = function()
        vim.notify("Use search to filter comments", vim.log.levels.INFO)
      end,
    },
  })
end

function M.pick_commits(entries, on_select, opts)
  local fzf = require("fzf-lua")
  local utils = require("fzf-lua.utils")

  local display_list = {}
  for i, entry in ipairs(entries) do
    local display
    if entry.type == "commit" and entry.additions then
      local short = (entry.sha or ""):sub(1, 8)
      display = string.format(
        "  %s  %s  %s %s  (%s)",
        short,
        entry.title or "",
        utils.ansi_codes.green(string.format("+%d", entry.additions)),
        utils.ansi_codes.red(string.format("-%d", entry.deletions)),
        entry.author or ""
      )
    else
      display = entry.display
    end
    table.insert(display_list, string.format("%d\t%s", i, display))
  end

  local default_idx = opts and opts.default_selection_index or 1
  local fzf_extra = {}
  if default_idx > 1 then
    fzf_extra["--sync"] = ""
    fzf_extra["--bind"] = string.format("start:pos(%d)", default_idx)
  end

  fzf.fzf_exec(display_list, {
    prompt = "Commits> ",
    previewer = false,
    fzf_opts = vim.tbl_extend("force", { ["--ansi"] = "", ["--with-nth"] = "2..", ["--delimiter"] = "\t" }, fzf_extra),
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local idx = tonumber(selected[1]:match("^(%d+)\t"))
          if idx and entries[idx] then
            on_select(entries[idx])
          end
        end
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
