local files_picker = require("codereview.picker.files")

describe("picker.files", function()
  describe("build_entries", function()
    it("builds entries for changed files with comment counts", function()
      local files = {
        { new_path = "src/auth.lua", old_path = "src/auth.lua" },
        { new_path = "src/utils.lua", old_path = "src/utils.lua" },
      }
      local discussions = {
        { resolved = false, notes = { { position = { new_path = "src/auth.lua", new_line = 10 } } } },
        { resolved = true,  notes = { { position = { new_path = "src/auth.lua", new_line = 20 } } } },
      }
      local ai_suggestions = {
        { file = "src/auth.lua", line = 15, severity = "warning", comment = "test", status = "pending" },
      }

      local entries = files_picker.build_entries(files, discussions, ai_suggestions)

      assert.equals(2, #entries)
      assert.equals("src/auth.lua", entries[1].file_path)
      assert.equals(1, entries[1].file_idx)
      assert.equals(2, entries[1].comment_count)
      assert.equals(1, entries[1].unresolved_count)
      assert.equals(1, entries[1].ai_count)
      assert.equals("src/utils.lua", entries[2].file_path)
      assert.equals(0, entries[2].comment_count)
      assert.equals(0, entries[2].unresolved_count)
      assert.equals(0, entries[2].ai_count)
    end)

    it("shows annotation counts in display string", function()
      local files = {
        { new_path = "src/auth.lua", old_path = "src/auth.lua" },
      }
      local discussions = {
        { resolved = false, notes = { { position = { new_path = "src/auth.lua", new_line = 10 } } } },
      }
      local entries = files_picker.build_entries(files, discussions, {})

      assert.truthy(entries[1].display:find("%[1%]"))
      assert.truthy(entries[1].display:find("⚠1"))
    end)

    it("returns empty list for empty files", function()
      local entries = files_picker.build_entries({}, {}, {})
      assert.equals(0, #entries)
    end)
  end)
end)
