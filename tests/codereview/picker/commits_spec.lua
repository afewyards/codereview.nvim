local commits_picker = require("codereview.picker.commits")

describe("commits picker", function()
  describe("build_entries", function()
    it("builds picker entries from commits", function()
      local commits = {
        {
          sha = "abc12345full",
          short_sha = "abc12345",
          title = "Fix login",
          author = "alice",
          created_at = "2026-03-01T10:00:00Z",
        },
        {
          sha = "def67890full",
          short_sha = "def67890",
          title = "Add tests",
          author = "bob",
          created_at = "2026-02-28T10:00:00Z",
        },
      }
      local entries = commits_picker.build_entries(commits, nil)
      assert.equals("all", entries[1].type)
      assert.truthy(entries[1].display:match("All changes"))
      assert.equals("commit", entries[2].type)
      assert.equals("abc12345full", entries[2].sha)
      assert.truthy(entries[2].display:match("abc12345"))
      assert.truthy(entries[2].display:match("Fix login"))
    end)

    it("includes since-last-review when last_reviewed_sha provided", function()
      local commits = {
        { sha = "sha1", short_sha = "sha1shor", title = "Old commit" },
        { sha = "sha2", short_sha = "sha2shor", title = "New commit" },
      }
      local entries = commits_picker.build_entries(commits, "sha1")
      local found = false
      for _, e in ipairs(entries) do
        if e.type == "since_last_review" then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("does not include since-last-review when 0 new commits", function()
      local commits = {
        { sha = "sha1", short_sha = "sha1shor", title = "Only commit" },
      }
      local entries = commits_picker.build_entries(commits, "sha1")
      local found = false
      for _, e in ipairs(entries) do
        if e.type == "since_last_review" then
          found = true
        end
      end
      assert.is_false(found)
    end)
  end)
end)
