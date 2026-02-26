local detail = require("codereview.mr.detail")

describe("mr.detail", function()
  describe("build_header_lines", function()
    it("builds header from normalized review data", function()
      local review = {
        id = 42,
        title = "Fix auth token refresh",
        author = "maria",
        source_branch = "fix/token-refresh",
        target_branch = "main",
        state = "opened",
        pipeline_status = "success",
        description = "Fixes the bug",
        web_url = "https://gitlab.com/group/project/-/merge_requests/42",
        approved_by = { "reviewer1" },
        approvals_required = 2,
      }
      local result = detail.build_header_lines(review)
      assert.truthy(#result.lines > 0)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("#42"))
      assert.truthy(joined:find("Fix auth token refresh"))
      assert.truthy(joined:find("maria"))
      assert.truthy(joined:find("approved"))
    end)

    it("strips markdown from description and returns highlights", function()
      local review = {
        id = 1, title = "Test", author = "me",
        source_branch = "feat", target_branch = "main",
        state = "opened", pipeline_status = "success",
        description = "This is **important** info",
        approved_by = {}, approvals_required = 0,
      }
      local result = detail.build_header_lines(review)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("This is important info"))
      assert.falsy(joined:find("%*%*"))
      assert.is_table(result.highlights)
      assert.truthy(#result.highlights > 0)
    end)

    it("returns struct with lines and empty highlights for no description", function()
      local review = {
        id = 1, title = "Test", author = "me",
        source_branch = "feat", target_branch = "main",
        state = "opened", pipeline_status = "success",
        description = "",
        approved_by = {}, approvals_required = 0,
      }
      local result = detail.build_header_lines(review)
      assert.is_table(result.lines)
      assert.is_table(result.highlights)
    end)

    it("renders markdown headers in description", function()
      local review = {
        id = 1, title = "Test", author = "me",
        source_branch = "feat", target_branch = "main",
        state = "opened", pipeline_status = "success",
        description = "## Summary\n\nThis fixes a bug",
        approved_by = {}, approvals_required = 0,
      }
      local result = detail.build_header_lines(review)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("Summary"))
      -- Should have H2 highlight
      local has_h2 = false
      for _, h in ipairs(result.highlights) do
        if h[4] == "CodeReviewMdH2" then has_h2 = true end
      end
      assert.is_true(has_h2)
    end)

    it("renders code blocks in description", function()
      local review = {
        id = 1, title = "Test", author = "me",
        source_branch = "feat", target_branch = "main",
        state = "opened", pipeline_status = "success",
        description = "```lua\nlocal x = 1\n```",
        approved_by = {}, approvals_required = 0,
      }
      local result = detail.build_header_lines(review)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("local x = 1"))
      local has_cb = false
      for _, h in ipairs(result.highlights) do
        if h[4] == "CodeReviewMdCodeBlock" then has_cb = true end
      end
      assert.is_true(has_cb)
    end)

    it("returns code_blocks in result struct", function()
      local review = {
        id = 1, title = "Test", author = "me",
        source_branch = "feat", target_branch = "main",
        state = "opened", pipeline_status = "success",
        description = "```lua\nlocal x = 1\n```",
        approved_by = {}, approvals_required = 0,
      }
      local result = detail.build_header_lines(review)
      assert.is_table(result.code_blocks)
      assert.equals(1, #result.code_blocks)
      assert.equals("lua", result.code_blocks[1].lang)
    end)
  end)

  describe("build_activity_lines", function()
    it("formats general discussion threads", function()
      local discussions = {
        {
          id = "abc",
          individual_note = true,
          notes = {
            {
              id = 1,
              body = "Looks good!",
              author = "jan",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("Looks good"))
    end)

    it("formats system notes as compact lines", function()
      local discussions = {
        {
          id = "def",
          individual_note = true,
          notes = {
            {
              id = 2,
              body = "approved this merge request",
              author = "jan",
              created_at = "2026-02-20T11:00:00Z",
              system = true,
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("approved"))
      -- System notes should have a Nerd Font icon (3-byte UTF-8 sequences)
      local has_icon = false
      for _, l in ipairs(result.lines) do
        -- Check for any of the activity icon bytes (all start with 0xef)
        if l:find("\xef", 1, true) then has_icon = true end
      end
      assert.is_true(has_icon)
    end)

    it("returns structured result with lines, highlights, and row_map", function()
      local discussions = {
        {
          id = "abc",
          notes = {
            {
              id = 1,
              body = "Looks good!",
              author = "jan",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      assert.is_table(result.lines)
      assert.is_table(result.highlights)
      assert.is_table(result.row_map)
    end)

    it("renders comment thread with header/footer and raw markdown body", function()
      local discussions = {
        {
          id = "abc",
          notes = {
            {
              id = 1,
              body = "Looks good!",
              author = "jan",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      -- Box header with author
      assert.truthy(joined:find("┌"))
      assert.truthy(joined:find("@jan"))
      -- Body line (raw markdown, no │ prefix)
      assert.truthy(joined:find("Looks good"))
      -- Footer with resolved keymap labels (defaults: r, gt)
      assert.truthy(joined:find("└"))
      assert.truthy(joined:find("reply"))
      assert.truthy(joined:find("resolve"))
    end)

    it("renders replies with arrow notation", function()
      local discussions = {
        {
          id = "abc",
          notes = {
            {
              id = 1,
              body = "Fix this",
              author = "alice",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
            },
            {
              id = 2,
              body = "Done",
              author = "bob",
              created_at = "2026-02-20T11:00:00Z",
              system = false,
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("↪"))
      assert.truthy(joined:find("@bob"))
      assert.truthy(joined:find("Done"))
    end)

    it("includes resolved/unresolved status in header", function()
      local discussions = {
        {
          id = "abc",
          resolved = false,
          notes = {
            {
              id = 1,
              body = "Bug here",
              author = "alice",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
              resolvable = true,
              resolved = false,
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("Unresolved"))
    end)

    it("maps thread rows to discussions in row_map", function()
      local disc = {
        id = "abc",
        notes = {
          {
            id = 1,
            body = "Comment",
            author = "jan",
            created_at = "2026-02-20T10:00:00Z",
            system = false,
          },
        },
      }
      local result = detail.build_activity_lines({ disc })
      -- Find at least one row_map entry pointing to this discussion
      local found = false
      for _, entry in pairs(result.row_map) do
        if entry.discussion and entry.discussion.id == "abc" then
          found = true
          break
        end
      end
      assert.is_true(found)
    end)

    it("excludes inline discussions (with position) from Discussions section", function()
      local discussions = {
        {
          id = "abc",
          notes = {
            {
              id = 1,
              body = "Inline note",
              author = "jan",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
              position = { new_path = "foo.lua", new_line = 10 },
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      -- Inline note is excluded from the Discussions section
      assert.falsy(joined:find("Inline note"))
      -- And its file path is not shown
      assert.falsy(joined:find("foo.lua:10"))
    end)

    it("strips markdown from comment body and adds highlights", function()
      local discussions = {
        {
          id = "md",
          notes = {
            {
              id = 1,
              body = "This is **important**",
              author = "jan",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("This is important"))
      assert.falsy(joined:find("%*%*"))
      local has_bold = false
      for _, hl in ipairs(result.highlights) do
        if hl[4] == "CodeReviewCommentBold" then has_bold = true end
      end
      assert.is_true(has_bold)
    end)

    it("strips markdown from reply body", function()
      local discussions = {
        {
          id = "md2",
          notes = {
            {
              id = 1,
              body = "Fix this",
              author = "alice",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
            },
            {
              id = 2,
              body = "Done, see `fix()`",
              author = "bob",
              created_at = "2026-02-20T11:00:00Z",
              system = false,
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("Done, see fix%(%)"))
      assert.falsy(joined:find("`fix"))
    end)

    it("renders code blocks in comment body", function()
      local discussions = {
        {
          id = "cb",
          notes = {
            {
              id = 1,
              body = "```lua\nlocal x = 1\n```",
              author = "jan",
              created_at = "2026-02-20T10:00:00Z",
              system = false,
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("local x = 1"))
      local has_cb = false
      for _, h in ipairs(result.highlights) do
        if h[4] == "CodeReviewMdCodeBlock" then has_cb = true end
      end
      assert.is_true(has_cb)
    end)

    it("renders Activity section header", function()
      local discussions = {
        { id = "s1", notes = {{ id = 1, author = "olaf", body = "assigned to @olaf",
          created_at = "2026-02-20T11:00:00Z", system = true, resolvable = false, resolved = false }} },
      }
      local result = detail.build_activity_lines(discussions, 60)
      local found = false
      for _, l in ipairs(result.lines) do
        if l:match("^## Activity") then found = true end
      end
      assert.is_truthy(found)
    end)

    it("renders Discussions section header with unresolved count", function()
      local discussions = {
        { id = "d1", resolved = false, notes = {{ id = 1, author = "alice", body = "fix this",
          created_at = "2026-02-20T11:00:00Z", system = false, resolvable = true, resolved = false }} },
      }
      local result = detail.build_activity_lines(discussions, 60)
      local found = false
      for _, l in ipairs(result.lines) do
        if l:match("## Discussions.*unresolved") then found = true end
      end
      assert.is_truthy(found)
    end)

    it("excludes inline comments from Discussions section", function()
      local discussions = {
        { id = "d1", resolved = false, notes = {{ id = 1, author = "alice", body = "fix this",
          created_at = "2026-02-20T11:00:00Z", system = false, resolvable = true, resolved = false,
          position = { new_path = "src/auth.ts", new_line = 42 } }} },
      }
      local result = detail.build_activity_lines(discussions, 60)
      local found = false
      for _, l in ipairs(result.lines) do
        if l:find("src/auth.ts:42") then found = true end
      end
      assert.is_falsy(found)
    end)

    it("assigns no file_path row_map entries for inline-only discussions", function()
      local discussions = {
        { id = "d1", resolved = false, notes = {{ id = 1, author = "alice", body = "fix this",
          created_at = "2026-02-20T11:00:00Z", system = false, resolvable = true, resolved = false,
          position = { new_path = "src/auth.ts", new_line = 42 } }} },
      }
      local result = detail.build_activity_lines(discussions, 60)
      local found_file_row = false
      for _, entry in pairs(result.row_map) do
        if entry.type == "file_path" then found_file_row = true end
      end
      assert.is_falsy(found_file_row)
    end)

    it("still renders system notes as simple lines", function()
      local discussions = {
        {
          id = "def",
          notes = {
            {
              id = 2,
              body = "approved this merge request",
              author = "jan",
              created_at = "2026-02-20T11:00:00Z",
              system = true,
            },
          },
        },
      }
      local result = detail.build_activity_lines(discussions)
      local joined = table.concat(result.lines, "\n")
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("approved"))
      -- System notes should NOT have box drawing (┌ only appears for user threads)
      assert.falsy(joined:find("┌"))
      -- System notes should have a Nerd Font icon
      local has_icon = false
      for _, l in ipairs(result.lines) do
        if l:find("\xef", 1, true) then has_icon = true end
      end
      assert.is_true(has_icon)
    end)

    it("renders discussions newest first", function()
      local discussions = {
        { id = "old", notes = {{ id = 1, author = "alice", body = "Old comment",
          created_at = "2026-02-20T10:00:00Z", system = false }} },
        { id = "new", notes = {{ id = 2, author = "bob", body = "New comment",
          created_at = "2026-02-25T14:00:00Z", system = false }} },
      }
      local result = detail.build_activity_lines(discussions, 60)
      local joined = table.concat(result.lines, "\n")
      local new_pos = joined:find("New comment")
      local old_pos = joined:find("Old comment")
      assert.is_truthy(new_pos)
      assert.is_truthy(old_pos)
      assert.is_true(new_pos < old_pos)
    end)
  end)

  describe("build_header_lines redesign", function()
    it("renders bordered header card", function()
      local review = {
        id = 42, title = "Fix auth", author = "maria",
        source_branch = "fix/token", target_branch = "main",
        state = "opened", pipeline_status = "success",
        approved_by = { "alice" }, approvals_required = 2,
        description = "", merge_status = "can_be_merged",
      }
      local result = detail.build_header_lines(review, 60)
      -- Use find with plain string (not pattern) for multi-byte box-drawing chars
      local top = result.lines[1]
      assert.is_truthy(top:find("╭", 1, true) and top:find("╮", 1, true))
      local found_bottom = false
      for _, l in ipairs(result.lines) do
        if l:find("╰", 1, true) and l:find("╯", 1, true) then found_bottom = true end
      end
      assert.is_truthy(found_bottom)
    end)

    it("includes state in header", function()
      local review = {
        id = 42, title = "Fix auth", author = "maria",
        source_branch = "fix/token", target_branch = "main",
        state = "opened", pipeline_status = "success",
        approved_by = {}, approvals_required = 0,
        description = "",
      }
      local result = detail.build_header_lines(review, 60)
      local has_state = false
      for _, l in ipairs(result.lines) do
        if l:find("opened") then has_state = true end
      end
      assert.is_truthy(has_state)
    end)

    it("shows description section header", function()
      local review = {
        id = 42, title = "Fix", author = "m",
        source_branch = "a", target_branch = "b",
        state = "opened", description = "Hello world",
        approved_by = {}, approvals_required = 0,
      }
      local result = detail.build_header_lines(review, 60)
      local found = false
      for _, l in ipairs(result.lines) do
        if l:match("^## Description") then found = true end
      end
      assert.is_truthy(found)
    end)

    it("omits description section when empty", function()
      local review = {
        id = 42, title = "Fix", author = "m",
        source_branch = "a", target_branch = "b",
        state = "opened", description = "",
        approved_by = {}, approvals_required = 0,
      }
      local result = detail.build_header_lines(review, 60)
      for _, l in ipairs(result.lines) do
        assert.is_falsy(l:match("^## Description"))
      end
    end)
  end)

  describe("draft resume on open", function()
    it("enters review session and populates local_drafts when drafts resumed", function()
      local session = require("codereview.review.session")
      session.reset()
      local state = { local_drafts = {}, discussions = {} }
      local server_drafts = {
        { notes = {{ author = "You (draft)", body = "fix", position = { new_path = "a.lua", new_line = 1 } }}, is_draft = true, server_draft_id = 1 },
      }

      detail._apply_resumed_drafts(state, server_drafts)

      assert.is_true(session.get().active)
      assert.equal(1, #state.local_drafts)
      assert.equal(1, #state.discussions)

      session.reset()
    end)
  end)
end)
