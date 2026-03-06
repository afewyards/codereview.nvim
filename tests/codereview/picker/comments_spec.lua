local comments_picker = require("codereview.picker.comments")

describe("picker.comments", function()
  describe("build_entries", function()
    local discussions = {
      {
        id = 1,
        resolved = false,
        notes = {
          {
            author = { username = "alice" },
            body = "Fix this bug please",
            position = { new_path = "src/auth.lua", new_line = 42 },
          },
        },
      },
      {
        id = 2,
        resolved = true,
        notes = {
          {
            author = { username = "bob" },
            body = "Looks good now",
            position = { new_path = "src/utils.lua", new_line = 10 },
          },
        },
      },
    }
    local ai_suggestions = {
      {
        file = "src/auth.lua",
        line = 15,
        severity = "warning",
        comment = "Variable shadowing detected",
        status = "pending",
      },
      { file = "src/utils.lua", line = 20, severity = "info", comment = "Consider refactoring", status = "dismissed" },
    }
    local files = {
      { new_path = "src/auth.lua", old_path = "src/auth.lua" },
      { new_path = "src/utils.lua", old_path = "src/utils.lua" },
    }

    it("builds entries for discussions and active AI suggestions", function()
      local entries = comments_picker.build_entries(discussions, ai_suggestions, files)
      -- 2 discussions + 1 active AI (dismissed one excluded)
      assert.equals(3, #entries)
    end)

    it("marks discussion entries with type and metadata", function()
      local entries = comments_picker.build_entries(discussions, {}, files)
      assert.equals("discussion", entries[1].type)
      assert.equals("src/auth.lua", entries[1].file_path)
      assert.equals(42, entries[1].line)
      assert.equals(1, entries[1].file_idx)
    end)

    it("marks AI suggestion entries with type and metadata", function()
      local entries = comments_picker.build_entries({}, ai_suggestions, files)
      -- Only non-dismissed
      assert.equals(1, #entries)
      assert.equals("ai_suggestion", entries[1].type)
      assert.equals("src/auth.lua", entries[1].file_path)
      assert.equals(15, entries[1].line)
    end)

    it("includes resolved status in discussion display", function()
      local entries = comments_picker.build_entries(discussions, {}, files)
      assert.truthy(entries[1].display:find("unresolved"))
      assert.truthy(entries[2].display:find("resolved"))
    end)

    it("filters unresolved only", function()
      local entries = comments_picker.build_entries(discussions, ai_suggestions, files, "unresolved")
      -- 1 unresolved discussion + 1 active AI suggestion
      assert.equals(2, #entries)
    end)

    it("filters resolved only", function()
      local entries = comments_picker.build_entries(discussions, ai_suggestions, files, "resolved")
      -- 1 resolved discussion only (AI suggestions are never "resolved")
      assert.equals(1, #entries)
    end)

    it("returns empty for no data", function()
      local entries = comments_picker.build_entries({}, {}, {})
      assert.equals(0, #entries)
    end)
  end)

  describe("format_preview", function()
    it("formats ai_suggestion entry with bold severity and code block", function()
      local entry = {
        type = "ai_suggestion",
        suggestion = {
          severity = "warning",
          file = "src/auth.lua",
          line = 42,
          code = "local x = 1",
          comment = "Variable shadowing detected",
        },
      }
      local result = comments_picker.format_preview(entry)
      assert.truthy(result:find("%*%*%[warning%]%*%*"))
      assert.truthy(result:find("src/auth%.lua:42"))
      assert.truthy(result:find("```"))
      assert.truthy(result:find("local x = 1"))
      assert.truthy(result:find("Variable shadowing detected"))
    end)

    it("formats ai_suggestion without code block when no code", function()
      local entry = {
        type = "ai_suggestion",
        suggestion = {
          severity = "info",
          file = "src/utils.lua",
          line = 10,
          comment = "Consider refactoring",
        },
      }
      local result = comments_picker.format_preview(entry)
      assert.falsy(result:find("```"))
      assert.truthy(result:find("Consider refactoring"))
    end)

    it("formats discussion entry with bold author names", function()
      local entry = {
        type = "discussion",
        discussion = {
          notes = {
            { author = "alice", body = "Fix this please" },
            { author = "bob", body = "Done" },
          },
        },
      }
      local result = comments_picker.format_preview(entry)
      assert.truthy(result:find("%*%*@alice:%*%*"))
      assert.truthy(result:find("Fix this please"))
      assert.truthy(result:find("%*%*@bob:%*%*"))
      assert.truthy(result:find("Done"))
    end)

    it("uses 'unknown' for missing author in discussion", function()
      local entry = {
        type = "discussion",
        discussion = {
          notes = { { body = "Anonymous comment" } },
        },
      }
      local result = comments_picker.format_preview(entry)
      assert.truthy(result:find("%*%*@unknown:%*%*"))
    end)

    it("returns (no preview) for unknown entry type", function()
      local entry = { type = "other" }
      local result = comments_picker.format_preview(entry)
      assert.equals("(no preview)", result)
    end)
  end)
end)
