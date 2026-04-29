local M = {}
local Progress = {}
Progress.__index = Progress

--- Create a new progress tracker backed by a tmp file.
--- The tmp file path is exposed as `p.path` so prompt builders can embed it.
---
--- @return table  Progress object with :count(), :watch(on_change), :cleanup()
function M.new()
  local dir = vim.fn.stdpath("state") .. "/codereview"
  vim.fn.mkdir(dir, "p")
  local path = string.format("%s/run-%d-%d.progress", dir, os.time(), math.random(1000000))
  local f = io.open(path, "w")
  if f then
    f:close()
  end
  return setmetatable({ path = path }, Progress)
end

--- Count completed-file lines written to the progress file.
--- @return integer
function Progress:count()
  local f = io.open(self.path, "r")
  if not f then
    return 0
  end
  local n = 0
  for _ in f:lines() do
    n = n + 1
  end
  f:close()
  return n
end

--- Poll the progress file every 250 ms and call on_change(count) when it changes.
--- @param on_change fun(count: integer)
function Progress:watch(on_change)
  self._timer = vim.uv.new_timer()
  self._timer:start(
    250,
    250,
    vim.schedule_wrap(function()
      if self._stopped then
        return
      end
      on_change(self:count())
    end)
  )
end

--- Stop the poll timer and delete the tmp file.
function Progress:cleanup()
  self._stopped = true
  if self._timer then
    self._timer:stop()
    self._timer:close()
    self._timer = nil
  end
  os.remove(self.path)
end

return M
