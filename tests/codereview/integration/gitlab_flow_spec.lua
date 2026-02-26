-- tests/codereview/integration/gitlab_flow_spec.lua
-- Integration tests: raw GitLab data → normalized shapes → display functions

require("tests.unit_helper")

-- Stub modules that pull in vim API or network deps
package.preload["codereview.providers"] = function()
  return { detect = function() return nil, nil, "stub" end }
end
package.preload["codereview.api.client"] = function()
  return {}
end

local gitlab = require("codereview.providers.gitlab")
local detail = require("codereview.mr.detail")
local comment = require("codereview.mr.comment")

describe("GitLab integration flow", function()
  describe("normalize_mr", function()
    it("flattens nested author, diff_refs, pipeline and approved_by to strings", function()
      local raw_mr = {
        iid = 42,
        title = "Fix bug",
        author = { username = "alice" },
        source_branch = "fix/bug",
        target_branch = "main",
        state = "opened",
        diff_refs = { base_sha = "aaa", head_sha = "bbb", start_sha = "ccc" },
        web_url = "https://gitlab.com/mr/42",
        description = "desc",
        head_pipeline = { status = "success" },
        approved_by = { { user = { username = "bob" } } },
        approvals_before_merge = 1,
        sha = "bbb",
      }

      local review = gitlab.normalize_mr(raw_mr)

      assert.equal(42, review.id)
      assert.equal("alice", review.author)       -- string, not nested object
      assert.equal("aaa", review.base_sha)
      assert.equal("bbb", review.head_sha)
      assert.equal("ccc", review.start_sha)      -- preserved from diff_refs
      assert.equal("success", review.pipeline_status)
      assert.equal(1, #review.approved_by)
      assert.equal("bob", review.approved_by[1]) -- string, not nested object
    end)

    it("handles missing optional fields gracefully", function()
      local raw_mr = {
        iid = 7,
        title = "WIP",
        author = { username = "dev" },
        source_branch = "feat/x",
        target_branch = "main",
        state = "opened",
        diff_refs = { base_sha = "x", head_sha = "y", start_sha = "z" },
      }

      local review = gitlab.normalize_mr(raw_mr)

      assert.equal(7, review.id)
      assert.is_nil(review.pipeline_status)
      assert.equal(0, #review.approved_by)
    end)
  end)

  describe("build_header_lines with normalized review", function()
    it("renders #id, author, pipeline and approved_by as strings", function()
      local review = {
        id = 42,
        title = "Fix the bug",
        author = "alice",
        source_branch = "fix/bug",
        target_branch = "main",
        state = "opened",
        pipeline_status = "success",
        approved_by = { "alice", "bob" },
        approvals_required = 2,
        description = "",
      }

      local lines = detail.build_header_lines(review).lines

      -- Should contain #42 (not !42 which would be GitLab-specific raw notation)
      local found_id = false
      for _, line in ipairs(lines) do
        if line:find("#42") then found_id = true end
      end
      assert.is_true(found_id, "header should contain #42")

      -- Approvals should be rendered as count format
      local found_approvals = false
      for _, line in ipairs(lines) do
        if line:find("2/2 approved") then found_approvals = true end
      end
      assert.is_true(found_approvals, "header should contain 2/2 approved")
    end)

    it("shows pipeline icon for success status", function()
      local review = {
        id = 1,
        title = "T",
        author = "dev",
        source_branch = "br",
        target_branch = "main",
        state = "opened",
        pipeline_status = "success",
        approved_by = {},
        approvals_required = 0,
        description = "",
      }

      local lines = detail.build_header_lines(review).lines

      local found_ok = false
      for _, line in ipairs(lines) do
        if line:find("%[ok%]") then found_ok = true end
      end
      assert.is_true(found_ok, "success pipeline should show [ok] icon")
    end)
  end)

  describe("build_activity_lines with normalized discussions", function()
    it("renders string author field from normalized notes", function()
      local discussions = {
        {
          notes = {
            {
              id = 1,
              author = "alice",       -- already a string (normalized)
              body = "looks good",
              created_at = "2026-01-01T10:00:00Z",
              system = false,
              resolvable = false,
              resolved = false,
              position = nil,         -- general comment, no diff position
            },
          },
        },
      }

      local result = detail.build_activity_lines(discussions)

      assert.is_true(#result.lines > 0, "activity lines should not be empty")

      local found_author = false
      for _, line in ipairs(result.lines) do
        if line:find("@alice") then found_author = true end
      end
      assert.is_true(found_author, "activity should render @alice")
    end)

    it("renders system notes with Nerd Font icon in Activity section", function()
      local discussions = {
        {
          notes = {
            {
              id = 2,
              author = "gitlab",
              body = "assigned to bob",
              created_at = "2026-01-01T09:00:00Z",
              system = true,
              resolvable = false,
              resolved = false,
              position = nil,
            },
          },
        },
      }

      local result = detail.build_activity_lines(discussions)

      local found_system = false
      for _, line in ipairs(result.lines) do
        -- System notes now render with a Nerd Font icon (3-byte UTF-8 starting with 0xef)
        if line:find("\xef", 1, true) and line:find("@gitlab") then found_system = true end
      end
      assert.is_true(found_system, "system notes should render with Nerd Font icon")
    end)

    it("excludes inline discussions (with diff position) from Discussions section", function()
      local discussions = {
        {
          notes = {
            {
              id = 3,
              author = "bob",
              body = "nit",
              created_at = "2026-01-01T08:00:00Z",
              system = false,
              resolvable = true,
              resolved = false,
              position = { new_path = "foo.lua", new_line = 5 },
            },
          },
        },
      }

      local result = detail.build_activity_lines(discussions)

      -- Inline comments should NOT appear in the summary — they belong in the diff
      local found_bob = false
      for _, line in ipairs(result.lines) do
        if line:find("@bob") then found_bob = true end
      end
      assert.is_false(found_bob, "inline discussion should not appear in Discussions section")
    end)
  end)

  describe("build_thread_lines with normalized discussion", function()
    it("renders string author and resolved_by fields", function()
      local disc = {
        notes = {
          {
            id = 1,
            author = "alice",       -- string (normalized)
            body = "change this please",
            created_at = "2026-01-01T10:00:00Z",
            resolvable = true,
            resolved = true,
            resolved_by = "bob",    -- string (normalized)
            position = { new_path = "foo.lua", new_line = 10 },
          },
        },
      }

      local lines = comment.build_thread_lines(disc)

      assert.is_true(#lines > 0, "thread lines should not be empty")

      -- First line: @author
      assert.truthy(lines[1]:find("@alice"), "first line should contain @alice")

      -- Resolved by bob should appear somewhere
      local found_resolved_by = false
      for _, line in ipairs(lines) do
        if line:find("bob") then found_resolved_by = true end
      end
      assert.is_true(found_resolved_by, "thread should mention resolved_by bob")
    end)

    it("renders unresolved status when not resolved", function()
      local disc = {
        notes = {
          {
            id = 2,
            author = "carol",
            body = "please fix",
            created_at = "2026-01-02T10:00:00Z",
            resolvable = true,
            resolved = false,
            resolved_by = nil,
            position = { new_path = "bar.lua", new_line = 20 },
          },
        },
      }

      local lines = comment.build_thread_lines(disc)

      local found_unresolved = false
      for _, line in ipairs(lines) do
        if line:find("Unresolved") then found_unresolved = true end
      end
      assert.is_true(found_unresolved, "unresolved thread should show [Unresolved]")
    end)

    it("renders replies with string author", function()
      local disc = {
        notes = {
          {
            id = 10,
            author = "alice",
            body = "root comment",
            created_at = "2026-01-01T10:00:00Z",
            resolvable = true,
            resolved = false,
            resolved_by = nil,
            position = { new_path = "foo.lua", new_line = 5 },
          },
          {
            id = 11,
            author = "bob",
            body = "I agree",
            created_at = "2026-01-01T10:05:00Z",
            resolvable = false,
            resolved = false,
          },
        },
      }

      local lines = comment.build_thread_lines(disc)

      local found_reply = false
      for _, line in ipairs(lines) do
        if line:find("@bob") then found_reply = true end
      end
      assert.is_true(found_reply, "reply author should be rendered")
    end)
  end)

  after_each(function()
    -- Clean up module cache to prevent test pollution
    package.loaded["codereview.providers"] = nil
    package.preload["codereview.providers"] = nil
  end)
end)

-- Load diff module for outdated comment placement tests
local diff = require("codereview.mr.diff")
local github = require("codereview.providers.github")

describe("outdated comment flow", function()
  local function make_buf(n)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, n do lines[i] = "line " .. i end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  local function make_line_data(new_lines)
    local ld = {}
    for _, nl in ipairs(new_lines) do
      table.insert(ld, { item = { new_line = nl, old_line = nl }, type = "context", file_idx = 1 })
    end
    return ld
  end

  local function find_virt_lines_row(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    for _, m in ipairs(marks) do
      if m[4] and m[4].virt_lines then
        return m[2] + 1  -- convert 0-indexed to 1-indexed
      end
    end
    return nil
  end

  it("GitLab: normalizes and remaps outdated comment", function()
    -- Raw GitLab discussion: position.head_sha is old, change_position is sibling of position
    local raw_disc = {
      id = "disc-gl-1",
      resolved = false,
      notes = {
        {
          id = 101,
          author = { username = "alice" },
          body = "This line changed",
          created_at = "2026-01-10T12:00:00Z",
          system = false,
          resolvable = true,
          resolved = false,
          position = {
            new_path = "src/foo.lua",
            old_path = "src/foo.lua",
            new_line = 10,
            old_line = 10,
            head_sha = "old-head",
            base_sha = "base-sha",
            start_sha = "start-sha",
          },
          -- change_position is a SIBLING of position (not nested inside)
          change_position = {
            new_path = "src/foo.lua",
            old_path = "src/foo.lua",
            new_line = 25,
            old_line = 25,
          },
        },
      },
    }

    local normalized = gitlab.normalize_discussion(raw_disc)

    -- SHAs must be preserved from position
    local note = normalized.notes[1]
    assert.equal("old-head", note.position.head_sha)
    assert.equal("base-sha", note.position.base_sha)
    assert.equal("start-sha", note.position.start_sha)

    -- change_position must be present on the normalized note
    assert.is_not_nil(note.change_position, "change_position should be preserved after normalization")
    assert.equal("src/foo.lua", note.change_position.new_path)
    assert.equal(25, note.change_position.new_line)

    -- Now simulate placing the comment into a diff buffer
    -- review.head_sha differs from position.head_sha => comment is outdated
    local review = { head_sha = "cur-head" }
    local buf = make_buf(30)
    -- line_data covers lines 20-26 (new_line=25 is the 6th entry)
    local line_data = make_line_data({ 20, 21, 22, 23, 24, 25, 26 })
    local file_diff = { new_path = "src/foo.lua", old_path = "src/foo.lua" }

    diff.place_comment_signs(buf, line_data, { normalized }, file_diff, nil, nil, review)

    local found_row = find_virt_lines_row(buf)
    -- change_position.new_line=25 is the 6th entry in line_data
    assert.equal(6, found_row, "outdated GitLab comment should land on the change_position row (25 = index 6)")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("GitHub: normalizes outdated comment with originalLine fallback", function()
    -- Raw GitHub thread: isOutdated=true, line=vim.NIL, originalLine=30
    local raw_threads = {
      {
        id = "thread-gh-1",
        isResolved = false,
        isOutdated = true,
        diffSide = "RIGHT",
        startDiffSide = vim.NIL,
        comments = {
          nodes = {
            {
              databaseId = 9001,
              id = "comment-node-1",
              author = { login = "bob" },
              body = "This is outdated",
              createdAt = "2026-01-15T09:30:00Z",
              path = "src/bar.lua",
              line = vim.NIL,         -- nil because the line no longer exists at HEAD
              originalLine = 30,      -- where the comment was originally placed
              startLine = vim.NIL,
              originalStartLine = vim.NIL,
              outdated = true,
              commit = { oid = "old-commit-sha" },
            },
          },
        },
      },
    }

    local discussions = github.normalize_graphql_threads(raw_threads)

    assert.equal(1, #discussions, "should produce one discussion")
    local note = discussions[1].notes[1]

    -- new_line should fall back to originalLine=30
    assert.equal(30, note.position.new_line, "new_line should be originalLine (30) when line is vim.NIL")

    -- outdated flag must be set
    assert.is_true(note.position.outdated, "position.outdated should be true for isOutdated thread")

    -- Now simulate placing the comment into a diff buffer
    local buf = make_buf(35)
    -- line_data covers lines 28-32 (new_line=30 is the 3rd entry)
    local line_data = make_line_data({ 28, 29, 30, 31, 32 })
    local file_diff = { new_path = "src/bar.lua", old_path = "src/bar.lua" }
    local review = { head_sha = "cur-head" }

    diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)

    local found_row = find_virt_lines_row(buf)
    -- new_line=30 is the 3rd entry in line_data
    assert.equal(3, found_row, "GitHub outdated comment should land on the originalLine row (30 = index 3)")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
