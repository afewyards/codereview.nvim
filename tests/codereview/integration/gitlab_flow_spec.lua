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

      local lines = detail.build_header_lines(review)

      -- Should contain #42 (not !42 which would be GitLab-specific raw notation)
      local found_id = false
      for _, line in ipairs(lines) do
        if line:find("#42") then found_id = true end
      end
      assert.is_true(found_id, "header should contain #42")

      -- Approvers should be rendered as @name strings
      local found_alice, found_bob = false, false
      for _, line in ipairs(lines) do
        if line:find("@alice") then found_alice = true end
        if line:find("@bob") then found_bob = true end
      end
      assert.is_true(found_alice, "header should contain @alice")
      assert.is_true(found_bob, "header should contain @bob")
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

      local lines = detail.build_header_lines(review)

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

      local lines = detail.build_activity_lines(discussions)

      assert.is_true(#lines > 0, "activity lines should not be empty")

      local found_author = false
      for _, line in ipairs(lines) do
        if line:find("@alice") then found_author = true end
      end
      assert.is_true(found_author, "activity should render @alice")
    end)

    it("renders system notes with dash prefix", function()
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

      local lines = detail.build_activity_lines(discussions)

      local found_system = false
      for _, line in ipairs(lines) do
        if line:find("^  %- @") then found_system = true end
      end
      assert.is_true(found_system, "system notes should render with dash prefix")
    end)

    it("skips discussions with a diff position (inline comments)", function()
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

      local lines = detail.build_activity_lines(discussions)

      -- Inline comment notes are skipped by build_activity_lines
      local found_bob = false
      for _, line in ipairs(lines) do
        if line:find("@bob") then found_bob = true end
      end
      assert.is_false(found_bob, "inline discussion should be skipped in activity")
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
end)
