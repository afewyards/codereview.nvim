-- tests/codereview/review/triage_spec.lua

-- Stub vim namespace for busted (no Neovim runtime)
_G.vim = _G.vim or {}
vim.api = vim.api or { nvim_create_namespace = function() return 0 end }
vim.bo = vim.bo or setmetatable({}, { __index = function() return {} end })
vim.wo = vim.wo or setmetatable({}, { __index = function() return {} end })
vim.fn = vim.fn or {}
vim.cmd = vim.cmd or function() end
vim.keymap = vim.keymap or { set = function() end }
vim.tbl_extend = vim.tbl_extend or function(_, a, b)
  local t = {}
  for k, v in pairs(a) do t[k] = v end
  for k, v in pairs(b) do t[k] = v end
  return t
end
vim.o = vim.o or { columns = 120, lines = 40 }
vim.split = vim.split or function(s, sep)
  local parts = {}
  for part in (s .. sep):gmatch("(.-)" .. sep) do table.insert(parts, part) end
  if parts[#parts] == "" then table.remove(parts) end
  return parts
end
vim.log = vim.log or { levels = { INFO = 1, WARN = 2, ERROR = 3 } }
vim.notify = vim.notify or function() end

-- Preload direct dependencies as stubs to avoid their transitive deps
package.preload["codereview.ui.split"] = function()
  return {
    create = function() return { sidebar_buf = 1, sidebar_win = 1, main_buf = 2, main_win = 2 } end,
    close = function() end,
  }
end

package.preload["codereview.mr.diff"] = function()
  return {
    render_file_diff = function() return {}, {} end,
  }
end

package.preload["codereview.review.submit"] = function()
  return {
    submit_review = function() end,
    filter_accepted = function() return {} end,
  }
end

local triage = require("codereview.review.triage")

describe("review.triage", function()
  describe("build_sidebar_lines", function()
    it("renders suggestion list with status", function()
      local suggestions = {
        { file = "auth.lua", line = 15, comment = "Missing check", status = "accepted", severity = "warning" },
        { file = "auth.lua", line = 42, comment = "Error swallowed", status = "pending", severity = "error" },
        { file = "diff.lua", line = 23, comment = "Off-by-one", status = "pending", severity = "info" },
      }
      local lines = triage.build_sidebar_lines(suggestions, 2)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("auth.lua:15"))
      assert.truthy(joined:find("auth.lua:42"))
      assert.truthy(joined:find("Reviewed: 1/3"))
    end)

    it("skips deleted suggestions", function()
      local suggestions = {
        { file = "a.lua", line = 1, comment = "x", status = "deleted", severity = "info" },
        { file = "b.lua", line = 2, comment = "y", status = "pending", severity = "info" },
      }
      local lines = triage.build_sidebar_lines(suggestions, 2)
      local joined = table.concat(lines, "\n")
      assert.falsy(joined:find("a.lua:1"))
      assert.truthy(joined:find("b.lua:2"))
    end)

    it("counts edited as reviewed", function()
      local suggestions = {
        { file = "a.lua", line = 1, comment = "x", status = "edited", severity = "info" },
        { file = "b.lua", line = 2, comment = "y", status = "pending", severity = "info" },
      }
      local lines = triage.build_sidebar_lines(suggestions, 1)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Reviewed: 1/2"))
    end)
  end)
end)
