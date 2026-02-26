_G.vim = _G.vim or {}
vim.trim = vim.trim or function(s) return s:match("^%s*(.-)%s*$") end

local summary = require("codereview.ai.summary")

describe("ai.summary", function()
  describe("build_review_summary_prompt", function()
    it("includes MR title and suggestion stats", function()
      local review = { title = "Add login", description = "New login page" }
      local suggestions = {
        { status = "accepted", comment = "Fix null check", severity = "error" },
        { status = "dismissed", comment = "Rename var", severity = "info" },
        { status = "pending", comment = "Add test", severity = "warning" },
      }
      local diffs = {
        { new_path = "login.lua", diff = "+code" },
      }
      local prompt = summary.build_review_summary_prompt(review, diffs, suggestions)
      assert.truthy(prompt:find("Add login"))
      assert.truthy(prompt:find("constructive"))
      assert.truthy(prompt:find("positive"))
    end)
  end)

  describe("parse_review_summary", function()
    it("extracts text from markdown block", function()
      local output = "Here is the summary:\n\n```markdown\nGreat PR! Clean implementation.\n```\n"
      local result = summary.parse_review_summary(output)
      assert.equal("Great PR! Clean implementation.", result)
    end)

    it("falls back to trimmed output when no block", function()
      local output = "Solid work on the refactor."
      local result = summary.parse_review_summary(output)
      assert.equal("Solid work on the refactor.", result)
    end)
  end)
end)
