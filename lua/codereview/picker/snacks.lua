local M = {}

function M.pick_mr(entries, on_select)
  local snacks = require("snacks")

  local items = {}
  for _, entry in ipairs(entries) do
    table.insert(items, {
      text = entry.display,
      data = entry,
    })
  end

  snacks.picker({
    title = "Code Reviews",
    items = items,
    format = function(item)
      return item.text
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        on_select(item.data)
      end
    end,
  })
end

return M
