local M = {}

function M.pick_mr(entries, on_select)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
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
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then on_select(selection.value) end
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
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then on_select(selection.value) end
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

return M
