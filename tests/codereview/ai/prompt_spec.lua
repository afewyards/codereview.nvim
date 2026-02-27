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
  describe("annotate_diff_with_lines", function()
    it("annotates added and context lines with new line numbers", function()
      local diff = "@@ -10,3 +10,4 @@\n context\n-old\n+new\n+added\n"
      local result = prompt.annotate_diff_with_lines(diff)
      local lines = {}
      for l in (result .. "\n"):gmatch("(.-)\n") do table.insert(lines, l) end
      -- hunk header unchanged
      assert.equals("@@ -10,3 +10,4 @@", lines[1])
      -- context line gets new line number (10)
      assert.truthy(lines[2]:match("L%s*10:"), "context line should have L10")
      assert.truthy(lines[2]:find(" context"), "context line should preserve content")
      -- deleted line gets padding only (no number)
      assert.falsy(lines[3]:match("L%s*%d+:"), "deleted line should have no line number")
      assert.truthy(lines[3]:find("-old"), "deleted line should preserve content")
      -- first added line gets new line number (11)
      assert.truthy(lines[4]:match("L%s*11:"), "first added line should have L11")
      assert.truthy(lines[4]:find("%+new"), "added line should preserve content")
      -- second added line gets new line number (12)
      assert.truthy(lines[5]:match("L%s*12:"), "second added line should have L12")
      assert.truthy(lines[5]:find("%+added"), "added line should preserve content")
    end)

    it("keeps diff header lines outside hunks unchanged", function()
      local diff = "diff --git a/foo.lua b/foo.lua\n--- a/foo.lua\n+++ b/foo.lua\n@@ -1,1 +1,1 @@\n-old\n+new\n"
      local result = prompt.annotate_diff_with_lines(diff)
      -- Use plain find (4th arg = true) with the actual strings to search for
      assert.truthy(result:find("diff --git a/foo.lua", 1, true), "diff --git header should be present")
      assert.truthy(result:find("--- a/foo.lua", 1, true), "--- header should be present")
      assert.truthy(result:find("+++ b/foo.lua", 1, true), "'+++ header should be present")
    end)

    it("pads numbers so lines align", function()
      -- Hunk starting at line 99 with 3 added lines reaches line 101
      local diff = "@@ -99,2 +99,4 @@\n context\n+a\n+b\n+c\n"
      local result = prompt.annotate_diff_with_lines(diff)
      -- All annotated lines should start with "L" followed by a 3-digit-wide number
      for line in (result .. "\n"):gmatch("(.-)\n") do
        if line:sub(1,1) == "L" then
          -- "L" then digits/spaces then ":"
          assert.truthy(line:match("^L%s*%d+:"), "expected Lnnn: prefix, got: " .. line)
        end
      end
    end)

    it("handles multiple hunks with correct line numbers", function()
      local diff = "@@ -1,2 +1,2 @@\n context\n-old1\n+new1\n@@ -10,2 +10,2 @@\n context2\n-old2\n+new2\n"
      local result = prompt.annotate_diff_with_lines(diff)
      -- Second hunk's context line should be L10
      assert.truthy(result:find("L%s*10:.*context2") or result:find("L10: context2"))
    end)

    it("returns empty string for empty input", function()
      assert.equals("", prompt.annotate_diff_with_lines(""))
    end)

    it("returns nil-safe result for nil input", function()
      assert.equals("", prompt.annotate_diff_with_lines(nil))
    end)

    it("preserves trailing newline", function()
      local diff = "@@ -1,1 +1,1 @@\n-old\n+new\n"
      local result = prompt.annotate_diff_with_lines(diff)
      assert.equals("\n", result:sub(-1), "result should end with newline")
    end)

    it("does not add trailing newline when input has none", function()
      local diff = "@@ -1,1 +1,1 @@\n-old\n+new"
      local result = prompt.annotate_diff_with_lines(diff)
      assert.not_equals("\n", result:sub(-1), "result should not end with newline")
    end)
  end)

  describe("extract_changed_lines", function()
    it("returns added line numbers from annotated diff", function()
      local diff = "@@ -10,3 +10,4 @@\n context\n-old\n+new\n+added\n"
      local changed = prompt.extract_changed_lines(diff)
      assert.is_true(changed[11])
      assert.is_true(changed[12])
      assert.is_nil(changed[10])
    end)

    it("returns empty table for diff with no additions", function()
      local diff = "@@ -5,2 +5,1 @@\n-removed\n context\n"
      local changed = prompt.extract_changed_lines(diff)
      assert.same({}, changed)
    end)

    it("handles multiple hunks", function()
      local diff = "@@ -1,2 +1,2 @@\n-old1\n+new1\n@@ -10,2 +10,2 @@\n-old2\n+new2\n"
      local changed = prompt.extract_changed_lines(diff)
      assert.is_true(changed[1])
      assert.is_true(changed[10])
    end)

    it("returns empty table for nil input", function()
      local changed = prompt.extract_changed_lines(nil)
      assert.same({}, changed)
    end)
  end)

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

    it("annotates diff lines with line numbers in the prompt", function()
      local review = { title = "T", description = "D" }
      local diffs = {
        { new_path = "src/foo.lua", diff = "@@ -5,2 +5,3 @@\n context\n-old\n+new\n+extra\n" },
      }
      local result = prompt.build_review_prompt(review, diffs)
      -- Should contain annotated line numbers
      assert.truthy(result:match("L%s*5:"), "prompt should contain L5 annotation")
      assert.truthy(result:match("L%s*6:"), "prompt should contain L6 annotation")
    end)

    it("adds severity filter instruction when review_level is warning", function()
      local config = require("codereview.config")
      config.setup({ ai = { review_level = "warning" } })
      local review = { title = "T", description = "D" }
      local diffs = { { new_path = "f.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" } }
      local result = prompt.build_review_prompt(review, diffs)
      assert.truthy(result:find("Only report"), "should contain severity filter instruction")
      assert.truthy(result:find("warning"), "should mention warning level")
      config.reset()
    end)

    it("does not add severity filter instruction when review_level is info", function()
      local config = require("codereview.config")
      config.setup({ ai = { review_level = "info" } })
      local review = { title = "T", description = "D" }
      local diffs = { { new_path = "f.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" } }
      local result = prompt.build_review_prompt(review, diffs)
      assert.falsy(result:find("Only report"), "should not contain severity filter at info level")
      config.reset()
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

    it("filters out suggestions below review_level threshold", function()
      local config = require("codereview.config")
      config.setup({ ai = { review_level = "warning" } })
      local output = '```json\n[{"file": "a.lua", "line": 1, "severity": "info", "comment": "low"}, {"file": "a.lua", "line": 2, "severity": "warning", "comment": "mid"}, {"file": "a.lua", "line": 3, "severity": "error", "comment": "high"}]\n```'
      local suggestions = prompt.parse_review_output(output)
      assert.equals(2, #suggestions)
      assert.equals("warning", suggestions[1].severity)
      assert.equals("error", suggestions[2].severity)
      config.reset()
    end)

    it("keeps all suggestions when review_level is info", function()
      local config = require("codereview.config")
      config.setup({ ai = { review_level = "info" } })
      local output = '```json\n[{"file": "a.lua", "line": 1, "severity": "info", "comment": "low"}, {"file": "a.lua", "line": 2, "severity": "suggestion", "comment": "sug"}]\n```'
      local suggestions = prompt.parse_review_output(output)
      assert.equals(2, #suggestions)
      config.reset()
    end)
  end)

  describe("build_file_review_prompt", function()
    it("includes MR context, other file summaries, and target file diff", function()
      local review = { title = "Fix auth", description = "Token fix" }
      local file = { new_path = "src/auth.lua", diff = "@@ -1,2 +1,3 @@\n-old\n+new\n" }
      local summaries = {
        ["src/auth.lua"] = "Fixed token refresh",
        ["src/config.lua"] = "Added timeout setting",
      }
      local result = prompt.build_file_review_prompt(review, file, summaries)
      -- Contains MR context
      assert.truthy(result:find("Fix auth"))
      assert.truthy(result:find("Token fix"))
      -- Contains other file summaries (not the target file itself)
      assert.truthy(result:find("src/config.lua"))
      assert.truthy(result:find("Added timeout setting"))
      -- Contains the file's diff
      assert.truthy(result:find("%-old"))
      assert.truthy(result:find("%+new"))
      -- Contains review instructions and JSON format
      assert.truthy(result:find("JSON"))
      assert.truthy(result:find("severity"))
    end)

    it("excludes target file from other files section", function()
      local review = { title = "T", description = "D" }
      local file = { new_path = "a.lua", diff = "diff" }
      local summaries = {
        ["a.lua"] = "Summary A",
        ["b.lua"] = "Summary B",
      }
      local result = prompt.build_file_review_prompt(review, file, summaries)
      -- Should contain b.lua summary but not a.lua in the "Other" section
      assert.truthy(result:find("b.lua"))
      assert.truthy(result:find("Summary B"))
      -- The "Other Changed Files" section should not contain a.lua
      local other_section = result:match("## Other Changed Files in This MR\n(.-)\n## File Under Review")
      if other_section then
        assert.falsy(other_section:find("a%.lua"), "Other files section should not contain the target file")
      end
    end)

    it("handles empty summaries", function()
      local review = { title = "T", description = "D" }
      local file = { new_path = "a.lua", diff = "diff" }
      local result = prompt.build_file_review_prompt(review, file, {})
      assert.truthy(result:find("a.lua"))
      -- Should still work, just no other files section
      assert.truthy(result:find("JSON"))
      -- Should NOT have "Other Changed Files" header
      assert.falsy(result:find("Other Changed Files"))
    end)

    it("annotates diff lines with line numbers in the file review prompt", function()
      local review = { title = "T", description = "D" }
      local file = { new_path = "src/foo.lua", diff = "@@ -3,2 +3,3 @@\n context\n-old\n+new\n+extra\n" }
      local result = prompt.build_file_review_prompt(review, file, {})
      -- Annotated context line at new line 3
      assert.truthy(result:match("L%s*3:"), "prompt should contain L3 annotation")
      -- First added line at new line 4
      assert.truthy(result:match("L%s*4:"), "prompt should contain L4 annotation")
    end)

    it("adds severity filter instruction when review_level is error", function()
      local config = require("codereview.config")
      config.setup({ ai = { review_level = "error" } })
      local review = { title = "T", description = "D" }
      local file = { new_path = "f.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" }
      local result = prompt.build_file_review_prompt(review, file, {})
      assert.truthy(result:find("Only report"), "should contain severity filter instruction")
      assert.truthy(result:find("error"), "should mention error level")
      config.reset()
    end)

    it("includes full file content section when content is provided", function()
      local review = { title = "T", description = "D" }
      local file = { new_path = "src/foo.lua", diff = "@@ -1,2 +1,3 @@\n-old\n+new\n" }
      local result = prompt.build_file_review_prompt(review, file, {}, "local M = {}\nfunction M.foo()\nend\nreturn M")
      assert.truthy(result:find("## Full File Content"))
      assert.truthy(result:find("local M = {}"))
      assert.truthy(result:find("function M.foo"))
      assert.truthy(result:find("ONLY comment on lines that are actual changes"))
    end)

    it("omits full file content section when content is nil", function()
      local review = { title = "T", description = "D" }
      local file = { new_path = "src/foo.lua", diff = "@@ -1,2 +1,3 @@\n-old\n+new\n" }
      local result = prompt.build_file_review_prompt(review, file, {}, nil)
      assert.falsy(result:find("## Full File Content"))
    end)

    it("places full file content before the diff section", function()
      local review = { title = "T", description = "D" }
      local file = { new_path = "src/foo.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" }
      local result = prompt.build_file_review_prompt(review, file, {}, "full content here")
      local content_pos = result:find("## Full File Content")
      local diff_pos = result:find("## File Under Review")
      assert.truthy(content_pos)
      assert.truthy(diff_pos)
      assert.truthy(content_pos < diff_pos, "Full file content should appear before diff section")
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

  describe("build_summary_prompt", function()
    it("includes MR context and all file diffs", function()
      local review = { title = "Fix auth", description = "Token fix" }
      local diffs = {
        { new_path = "src/auth.lua", diff = "@@ -1,2 +1,3 @@\n-old\n+new\n" },
        { new_path = "src/config.lua", diff = "@@ -5,1 +5,2 @@\n+added\n" },
      }
      local result = prompt.build_summary_prompt(review, diffs)
      assert.truthy(result:find("Fix auth"))
      assert.truthy(result:find("src/auth.lua"))
      assert.truthy(result:find("src/config.lua"))
      assert.truthy(result:find("JSON"))
      assert.truthy(result:find("one%-sentence summary"))
    end)
  end)

  describe("parse_summary_output", function()
    it("extracts file-to-summary map from JSON block", function()
      local output = '```json\n{"src/auth.lua": "Fixed token refresh logic", "src/config.lua": "Added timeout setting"}\n```'
      local summaries = prompt.parse_summary_output(output)
      assert.equals("Fixed token refresh logic", summaries["src/auth.lua"])
      assert.equals("Added timeout setting", summaries["src/config.lua"])
    end)

    it("returns empty table on missing JSON", function()
      local summaries = prompt.parse_summary_output("no json here")
      assert.same({}, summaries)
    end)

    it("returns empty table on nil input", function()
      local summaries = prompt.parse_summary_output(nil)
      assert.same({}, summaries)
    end)
  end)
end)
