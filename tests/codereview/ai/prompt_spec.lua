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
          for key, val in obj_str:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
            obj[key] = val
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
end)
