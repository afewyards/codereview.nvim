local M = {}

function M.pick_mr(entries, on_select)
  local fzf = require("fzf-lua")

  local display_to_entry = {}
  local display_list = {}
  for _, entry in ipairs(entries) do
    table.insert(display_list, entry.display)
    display_to_entry[entry.display] = entry
  end

  fzf.fzf_exec(display_list, {
    prompt = "GitLab MRs> ",
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

return M
