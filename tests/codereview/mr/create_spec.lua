-- tests/codereview/mr/create_spec.lua
-- Stub vim globals for unit testing
_G.vim = _G.vim or {}
vim.trim = vim.trim or function(s) return s:match("^%s*(.-)%s*$") end
vim.split = vim.split or function(s, sep)
  local parts = {}
  for part in (s .. sep):gmatch("(.-)" .. sep) do table.insert(parts, part) end
  return parts
end

local prompt_mod = require("codereview.ai.prompt")

describe("mr.create prompts", function()
  describe("build_mr_prompt", function()
    it("includes branch name and diff", function()
      local result = prompt_mod.build_mr_prompt("fix/auth-refresh", "@@ diff content @@")
      assert.truthy(result:find("fix/auth%-refresh"))
      assert.truthy(result:find("diff content"))
    end)
  end)

  describe("parse_mr_draft", function()
    it("extracts structured title and description", function()
      local output = "## Title\nFix auth token refresh\n\n## Description\nFixes the bug.\n- Better errors\n"
      local title, desc = prompt_mod.parse_mr_draft(output)
      assert.equals("Fix auth token refresh", title)
      assert.truthy(desc:find("Better errors"))
    end)

    it("falls back to first-line title", function()
      local output = "Fix auth token refresh\n\nFixes the bug."
      local title, desc = prompt_mod.parse_mr_draft(output)
      assert.equals("Fix auth token refresh", title)
      assert.equals("Fixes the bug.", desc)
    end)
  end)
end)
