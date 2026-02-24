-- Stub vim globals for busted
_G.vim = _G.vim or {}
vim.json = vim.json or {}

-- Use cjson if available, otherwise a simple converter
local ok, cjson = pcall(require, "cjson")
if ok then
  vim.json.decode = vim.json.decode or function(s) return cjson.decode(s) end
else
  -- Minimal JSON array decoder for test data: handles arrays of flat string/number objects
  vim.json.decode = vim.json.decode or function(s)
    s = s:match("^%s*(.-)%s*$")
    -- Handle empty array
    if s == "[]" then return {} end
    -- Strip outer brackets
    local inner = s:match("^%[(.*)%]$")
    if not inner then error("not an array: " .. s) end
    local result = {}
    -- Split on object boundaries: },{ or }  {
    -- We parse each {...} object individually
    local depth = 0
    local obj_start = nil
    for i = 1, #inner do
      local c = inner:sub(i, i)
      if c == "{" then
        depth = depth + 1
        if depth == 1 then obj_start = i end
      elseif c == "}" then
        depth = depth - 1
        if depth == 0 and obj_start then
          local obj_str = inner:sub(obj_start, i)
          local obj = {}
          -- Parse key-value pairs from flat object
          local function json_unescape(s)
            return (s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\\\", "\\")):gsub('\\"', '"')
          end
          for key, val in obj_str:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
            obj[key] = json_unescape(val)
          end
          for key, val in obj_str:gmatch('"([^"]+)"%s*:%s*(-?%d+)') do
            obj[key] = tonumber(val)
          end
          table.insert(result, obj)
          obj_start = nil
        end
      end
    end
    return result
  end
end

vim.trim = vim.trim or function(s) return s:match("^%s*(.-)%s*$") end
vim.split = vim.split or function(s, sep)
  local parts = {}
  local escaped = sep:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
  local pattern = "([^" .. escaped .. "]*)"
  for part in s:gmatch(pattern) do
    table.insert(parts, part)
  end
  -- Remove trailing empty string artifact from gmatch
  while #parts > 0 and parts[#parts] == "" do
    table.remove(parts)
  end
  return parts
end

local prompt = require("codereview.ai.prompt")

describe("ai.prompt", function()
  describe("build_review_prompt", function()
    it("includes MR title, file path, and JSON instruction", function()
      local review = { title = "Fix auth refresh", description = "Fixes silent token expiry" }
      local diffs = {
        { new_path = "src/auth.lua", diff = "@@ -10,3 +10,4 @@\n context\n-old\n+new\n+added\n" },
      }
      local result = prompt.build_review_prompt(review, diffs)
      assert.truthy(result:find("Fix auth refresh"))
      assert.truthy(result:find("src/auth.lua"))
      assert.truthy(result:find("JSON"))
    end)
  end)

  describe("parse_review_output", function()
    it("extracts JSON array from code block", function()
      local output = 'Here are my findings:\n\n```json\n[{"file": "src/auth.lua", "line": 15, "severity": "warning", "comment": "Missing error check"}, {"file": "src/auth.lua", "line": 42, "severity": "info", "comment": "Consider renaming"}]\n```'
      local suggestions = prompt.parse_review_output(output)
      assert.equals(2, #suggestions)
      assert.equals("src/auth.lua", suggestions[1].file)
      assert.equals(15, suggestions[1].line)
      assert.equals("Missing error check", suggestions[1].comment)
      assert.equals("pending", suggestions[1].status)
    end)

    it("preserves newlines in comment fields", function()
      local output = '```json\n[{"file": "src/auth.lua", "line": 10, "severity": "warning", "comment": "Missing nil check.\\n\\nAdd a guard before accessing resp.body."}]\n```'
      local suggestions = prompt.parse_review_output(output)
      assert.equals(1, #suggestions)
      assert.truthy(suggestions[1].comment:find("\n"), "comment should contain real newlines")
      assert.equals("Missing nil check.\n\nAdd a guard before accessing resp.body.", suggestions[1].comment)
    end)

    it("handles output with no JSON", function()
      local suggestions = prompt.parse_review_output("No issues found, looks good!")
      assert.equals(0, #suggestions)
    end)

    it("handles malformed JSON gracefully", function()
      local suggestions = prompt.parse_review_output('```json\n{broken\n```')
      assert.equals(0, #suggestions)
    end)

    it("handles nil input", function()
      local suggestions = prompt.parse_review_output(nil)
      assert.equals(0, #suggestions)
    end)
  end)

  describe("build_mr_prompt", function()
    it("includes branch name and instructions", function()
      local result = prompt.build_mr_prompt("fix/auth-refresh", "diff content here")
      assert.truthy(result:find("fix/auth%-refresh"))
      assert.truthy(result:find("Title"))
      assert.truthy(result:find("Description"))
    end)
  end)

  describe("parse_mr_draft", function()
    it("extracts title and description from structured output", function()
      local output = "## Title\nFix auth token refresh\n\n## Description\nFixes the bug.\n- Better errors\n"
      local title, desc = prompt.parse_mr_draft(output)
      assert.equals("Fix auth token refresh", title)
      assert.truthy(desc:find("Better errors"))
    end)

    it("falls back to first-line title", function()
      local output = "Fix auth token refresh\n\nFixes the bug."
      local title, desc = prompt.parse_mr_draft(output)
      assert.equals("Fix auth token refresh", title)
      assert.equals("Fixes the bug.", desc)
    end)
  end)

  describe("build_orchestrator_prompt", function()
    it("includes MR context and per-file Task instructions", function()
      local review = { title = "Fix auth refresh", description = "Fixes silent token expiry" }
      local diffs = {
        { new_path = "src/auth.lua", diff = "@@ -10,3 +10,4 @@\n-old\n+new\n" },
        { new_path = "src/config.lua", diff = "@@ -1,2 +1,3 @@\n+added\n" },
      }
      local result = prompt.build_orchestrator_prompt(review, diffs)
      -- Contains MR context
      assert.truthy(result:find("Fix auth refresh"))
      assert.truthy(result:find("Fixes silent token expiry"))
      -- Lists all files
      assert.truthy(result:find("src/auth.lua"))
      assert.truthy(result:find("src/config.lua"))
      -- Contains Task tool instruction
      assert.truthy(result:find("Task tool"))
      -- Contains subagent type instruction
      assert.truthy(result:find("code%-review"))
      -- Contains per-file diff content for embedding in subagent prompts
      assert.truthy(result:find("%-old"))
      assert.truthy(result:find("%+new"))
      assert.truthy(result:find("%+added"))
      -- Contains synthesis instruction
      assert.truthy(result:find("[Ss]ynthesi"))
      -- Contains JSON output format
      assert.truthy(result:find("JSON"))
    end)

    it("includes other file names in each file section for cross-file context", function()
      local review = { title = "Multi-file change", description = "desc" }
      local diffs = {
        { new_path = "a.lua", diff = "diff-a" },
        { new_path = "b.lua", diff = "diff-b" },
        { new_path = "c.lua", diff = "diff-c" },
      }
      local result = prompt.build_orchestrator_prompt(review, diffs)
      -- Each file section should reference other files
      assert.truthy(result:find("a.lua"))
      assert.truthy(result:find("b.lua"))
      assert.truthy(result:find("c.lua"))
      -- Verify that the a.lua section lists b.lua and c.lua as other changed files
      -- The section starts at "### File: `a.lua`"
      local a_section_start = result:find("### File: `a%.lua`")
      local a_section_end = result:find("### File: `b%.lua`") or #result
      local a_section = result:sub(a_section_start, a_section_end)
      assert.truthy(a_section:find("Other changed files:"), "a.lua section should have 'Other changed files' line")
      assert.truthy(a_section:find("b%.lua"), "a.lua section should mention b.lua as other file")
      assert.truthy(a_section:find("c%.lua"), "a.lua section should mention c.lua as other file")
      -- a.lua section should not list itself as an other file
      local other_files_line = a_section:match("Other changed files: ([^\n]+)")
      assert.falsy(other_files_line and other_files_line:find("a%.lua"), "a.lua section should not list itself")
    end)
  end)
end)
