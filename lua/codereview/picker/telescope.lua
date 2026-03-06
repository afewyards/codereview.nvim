local M = {}

function M.pick_mr(entries, on_select)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  local max_len = 0
  for _, entry in ipairs(entries) do
    max_len = math.max(max_len, vim.api.nvim_strwidth(entry.display))
  end
  local max_cols = math.floor(vim.o.columns * 0.9)
  local width = math.min(max_len + 5, max_cols)

  pickers
    .new({}, {
      layout_strategy = "vertical",
      layout_config = { width = width },
      prompt_title = "Code Reviews",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.display,
            ordinal = entry.title .. " " .. entry.author .. " " .. tostring(entry.id),
          }
        end,
      }),
      previewer = previewers.new_buffer_previewer({
        title = "Description",
        define_preview = function(self, entry)
          local text = require("codereview.mr.list").format_mr_preview(entry.value)
          local lines = vim.split(text, "\n", { plain = true })
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].syntax = "markdown"
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            on_select(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

function M.pick_files(entries, on_select)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers
    .new({}, {
      prompt_title = "Review Files",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.display,
            ordinal = entry.ordinal,
          }
        end,
      }),
      previewer = previewers.new_buffer_previewer({
        title = "Diff",
        define_preview = function(self, entry)
          local diff = entry.value.diff or "(no diff available)"
          local lines = vim.split(diff, "\n", { plain = true })
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].syntax = "diff"
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            on_select(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

function M.pick_comments(entries, on_select, opts)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  local filters = { "all", "unresolved", "resolved" }
  local filter_idx = 1
  local current_entries = entries

  local function make_finder(e)
    return finders.new_table({
      results = e,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.display,
          ordinal = entry.ordinal,
        }
      end,
    })
  end

  pickers
    .new({}, {
      prompt_title = "Comments & Suggestions [all]",
      finder = make_finder(current_entries),
      previewer = previewers.new_buffer_previewer({
        title = "Comment",
        define_preview = function(self, entry)
          local text = require("codereview.picker.comments").format_preview(entry.value)
          local lines = vim.split(text, "\n", { plain = true })
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
          vim.bo[self.state.bufnr].syntax = "markdown"
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            on_select(selection.value)
          end
        end)

        local filter_key = opts and opts.filter_key or "<C-r>"
        map("i", filter_key, function()
          filter_idx = (filter_idx % #filters) + 1
          local filter = filters[filter_idx] == "all" and nil or filters[filter_idx]
          if opts and opts.rebuild then
            current_entries = opts.rebuild(filter)
          end
          local picker_inst = action_state.get_current_picker(prompt_bufnr)
          picker_inst:refresh(make_finder(current_entries), { reset_prompt = false })
          picker_inst.prompt_border:change_title("Comments & Suggestions [" .. filters[filter_idx] .. "]")
        end)
        map("n", filter_key, function()
          filter_idx = (filter_idx % #filters) + 1
          local filter = filters[filter_idx] == "all" and nil or filters[filter_idx]
          if opts and opts.rebuild then
            current_entries = opts.rebuild(filter)
          end
          local picker_inst = action_state.get_current_picker(prompt_bufnr)
          picker_inst:refresh(make_finder(current_entries), { reset_prompt = false })
          picker_inst.prompt_border:change_title("Comments & Suggestions [" .. filters[filter_idx] .. "]")
        end)

        return true
      end,
    })
    :find()
end

function M.pick_commits(entries, on_select, opts)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local has_stats = false
  for _, e in ipairs(entries) do
    if e.additions then
      has_stats = true
      break
    end
  end

  local max_title, max_author = 0, 0
  for _, e in ipairs(entries) do
    if e.type == "commit" then
      max_title = math.max(max_title, #(e.title_display or e.title or ""))
      max_author = math.max(max_author, #(e.author or ""))
    end
  end

  -- Size picker to content: use column widths for formatted commit rows
  -- displayer: 2 + sep + 8 + sep + title + sep + 7 + sep + 7 + sep + "(" + author + ")"
  local commit_row_len = 2 + 1 + 8 + 1 + math.min(max_title, 85) + 1 + 1 + max_author + 1
  if has_stats then
    commit_row_len = commit_row_len + 7 + 1 + 7 + 1
  end
  local max_len = commit_row_len
  for _, e in ipairs(entries) do
    max_len = math.max(max_len, vim.api.nvim_strwidth(e.display))
  end
  local max_cols = math.floor(vim.o.columns * 0.9)
  local width = math.min(max_len + 5, max_cols)

  local make_entry
  if has_stats then
    local displayer = entry_display.create({
      separator = " ",
      items = {
        { width = 2 },
        { width = 8 },
        { width = math.min(max_title, 85) },
        { width = 7 },
        { width = 7 },
        { remaining = true },
      },
    })
    make_entry = function(entry)
      if entry.type ~= "commit" or not entry.additions then
        return { value = entry, display = entry.display, ordinal = entry.ordinal }
      end
      return {
        value = entry,
        ordinal = entry.ordinal,
        display = function()
          return displayer({
            { "  " },
            { (entry.sha or ""):sub(1, 8), "TelescopeResultsIdentifier" },
            { entry.title_display or entry.title or "" },
            { string.format("+%d", entry.additions), "diffAdded" },
            { string.format("-%d", entry.deletions), "diffRemoved" },
            { string.format("(%s)", entry.author or ""), "TelescopeResultsComment" },
          })
        end,
      }
    end
  else
    make_entry = function(entry)
      return { value = entry, display = entry.display, ordinal = entry.ordinal }
    end
  end

  pickers
    .new({}, {
      layout_strategy = "vertical",
      layout_config = { width = width, height = 0.8 },
      prompt_title = "Commits",
      default_selection_index = opts and opts.default_selection_index or 1,
      finder = finders.new_table({
        results = entries,
        entry_maker = make_entry,
      }),
      previewer = false,
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local sel = action_state.get_selected_entry()
          if sel then
            on_select(sel.value)
          end
        end)
        return true
      end,
    })
    :find()
end

function M.pick_branches(branches, on_select)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "Target Branch",
      finder = finders.new_table({ results = branches }),
      previewer = false,
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            on_select(selection[1])
          end
        end)
        return true
      end,
    })
    :find()
end

return M
