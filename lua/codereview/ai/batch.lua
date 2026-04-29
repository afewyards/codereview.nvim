local M = {}

--- Group diffs into batches by character budget and file count cap.
--- An oversize file (diff alone exceeds budget) goes in its own batch.
---
--- @param diffs table[]          List of {new_path, old_path, diff}
--- @param opts  table?           {char_budget: integer, max_files: integer}
--- @return table[][]             List of batches; each batch is a list of diffs
function M.build(diffs, opts)
  local budget = (opts and opts.char_budget) or 80000
  local cap = (opts and opts.max_files) or 15
  local batches = {}
  local cur = {}
  local cur_size = 0

  for _, f in ipairs(diffs) do
    local sz = #(f.diff or "")
    if (#cur > 0) and (cur_size + sz > budget or #cur >= cap) then
      table.insert(batches, cur)
      cur = {}
      cur_size = 0
    end
    table.insert(cur, f)
    cur_size = cur_size + sz
  end

  if #cur > 0 then
    table.insert(batches, cur)
  end

  return batches
end

return M
