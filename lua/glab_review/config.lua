-- lua/glab_review/config.lua
local M = {}

local defaults = {
  gitlab_url = nil,
  project = nil,
  token = nil,
  picker = nil,
  diff = { context = 8 },
  ai = { enabled = true, claude_cmd = "claude" },
}

local current = nil

local function deep_merge(base, override)
  local result = vim.deepcopy(base)
  for k, v in pairs(override) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

local function validate(c)
  c.diff.context = math.max(0, math.min(20, c.diff.context))
  return c
end

function M.setup(opts)
  current = validate(deep_merge(defaults, opts or {}))
end

function M.get()
  return current or vim.deepcopy(defaults)
end

function M.reset()
  current = nil
end

return M
