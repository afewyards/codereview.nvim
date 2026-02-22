-- tests/codereview/integration/github_flow_spec.lua
-- Integration tests: raw GitHub data → normalized shapes → display functions

require("tests.unit_helper")

-- Stub modules that pull in vim API or network deps
package.preload["codereview.providers"] = function()
  return { detect = function() return nil, nil, "stub" end }
end
package.preload["codereview.api.client"] = function()
  return {}
end

local github = require("codereview.providers.github")
local detail = require("codereview.mr.detail")

describe("GitHub integration flow", function()
  describe("normalize_pr", function()
    it("maps GitHub PR fields to normalized review", function()
      local pr = {
        number = 99,
        title = "Add feature",
        user = { login = "bob" },
        head = { ref = "feat/x", sha = "bbb" },
        base = { ref = "main", sha = "aaa" },
        state = "open",
        html_url = "https://github.com/owner/repo/pull/99",
        body = "description",
      }

      local review = github.normalize_pr(pr)

      assert.equal(99, review.id)
      assert.equal("bob", review.author)          -- string from user.login
      assert.equal("aaa", review.base_sha)
      assert.equal("bbb", review.head_sha)
      assert.equal("aaa", review.start_sha)       -- GitHub: start_sha == base_sha
      assert.equal("feat/x", review.source_branch)
      assert.equal("main", review.target_branch)
      assert.equal("open", review.state)
    end)

    it("uses number as id (not iid)", function()
      local pr = {
        number = 42,
        title = "T",
        user = { login = "u" },
        head = { ref = "br", sha = "h" },
        base = { ref = "main", sha = "b" },
        state = "open",
        html_url = "",
        body = "",
      }

      local review = github.normalize_pr(pr)

      assert.equal(42, review.id)
    end)

    it("sets start_sha equal to base_sha (no separate start sha in GitHub)", function()
      local pr = {
        number = 1,
        title = "T",
        user = { login = "u" },
        head = { ref = "br", sha = "HEAD123" },
        base = { ref = "main", sha = "BASE456" },
        state = "open",
        html_url = "",
        body = "",
      }

      local review = github.normalize_pr(pr)

      assert.equal("BASE456", review.base_sha)
      assert.equal("BASE456", review.start_sha)
      assert.equal(review.base_sha, review.start_sha)
    end)
  end)

  describe("normalize_review_comments_to_discussions", function()
    it("groups reply comments under root and sorts by created_at", function()
      local comments = {
        {
          id = 2,
          user = { login = "b" },
          body = "reply",
          created_at = "2026-01-01T00:01:00Z",
          path = "foo.lua",
          line = 10,
          side = "RIGHT",
          commit_id = "abc",
          in_reply_to_id = 1,
        },
        {
          id = 1,
          user = { login = "a" },
          body = "first",
          created_at = "2026-01-01T00:00:00Z",
          path = "foo.lua",
          line = 10,
          side = "RIGHT",
          commit_id = "abc",
          in_reply_to_id = nil,
        },
      }

      local discussions = github.normalize_review_comments_to_discussions(comments)

      assert.equal(1, #discussions)
      assert.equal(2, #discussions[1].notes)
      -- Root note first (sorted by created_at)
      assert.equal("a", discussions[1].notes[1].author)
      -- Reply second
      assert.equal("b", discussions[1].notes[2].author)
    end)

    it("creates separate discussions for unrelated root comments", function()
      local comments = {
        {
          id = 10,
          user = { login = "x" },
          body = "comment on line 5",
          created_at = "2026-01-01T00:00:00Z",
          path = "a.lua",
          line = 5,
          side = "RIGHT",
          commit_id = "abc",
          in_reply_to_id = nil,
        },
        {
          id = 20,
          user = { login = "y" },
          body = "comment on line 15",
          created_at = "2026-01-01T00:01:00Z",
          path = "a.lua",
          line = 15,
          side = "RIGHT",
          commit_id = "abc",
          in_reply_to_id = nil,
        },
      }

      local discussions = github.normalize_review_comments_to_discussions(comments)

      assert.equal(2, #discussions)
    end)

    it("produces notes with string author fields", function()
      local comments = {
        {
          id = 1,
          user = { login = "carol" },
          body = "nice",
          created_at = "2026-01-01T00:00:00Z",
          path = "f.lua",
          line = 1,
          side = "RIGHT",
          commit_id = "abc",
          in_reply_to_id = nil,
        },
      }

      local discussions = github.normalize_review_comments_to_discussions(comments)

      assert.equal(1, #discussions)
      assert.equal("carol", discussions[1].notes[1].author)
      assert.is_string(discussions[1].notes[1].author)
    end)
  end)

  describe("normalized GitHub review → build_header_lines", function()
    it("uses # prefix for PR id (not ! which is GitLab convention)", function()
      local pr = {
        number = 42,
        title = "Fix something",
        user = { login = "bob" },
        head = { ref = "feat/fix", sha = "bbb" },
        base = { ref = "main", sha = "aaa" },
        state = "open",
        html_url = "https://github.com/o/r/pull/42",
        body = "",
      }

      local review = github.normalize_pr(pr)
      local lines = detail.build_header_lines(review)

      local found_hash_id = false
      for _, line in ipairs(lines) do
        assert.falsy(line:find("!42"), "line should not use ! prefix: " .. line)
        if line:find("#42") then found_hash_id = true end
      end
      assert.is_true(found_hash_id, "header should contain #42")
    end)

    it("renders normalized author as @login string", function()
      local pr = {
        number = 7,
        title = "WIP",
        user = { login = "octocat" },
        head = { ref = "br", sha = "h" },
        base = { ref = "main", sha = "b" },
        state = "open",
        html_url = "",
        body = "",
      }

      local review = github.normalize_pr(pr)
      local lines = detail.build_header_lines(review)

      local found_author = false
      for _, line in ipairs(lines) do
        if line:find("@octocat") then found_author = true end
      end
      assert.is_true(found_author, "header should contain @octocat")
    end)

    it("shows no approvals block when approved_by is empty", function()
      local pr = {
        number = 5,
        title = "Small fix",
        user = { login = "dev" },
        head = { ref = "fix/small", sha = "h" },
        base = { ref = "main", sha = "b" },
        state = "open",
        html_url = "",
        body = "",
      }

      local review = github.normalize_pr(pr)
      -- GitHub PRs have no approved_by in normalized shape
      assert.equal(0, #review.approved_by)

      local lines = detail.build_header_lines(review)

      -- With 0 approved_by and 0 approvals_required, Approvals line is omitted
      local found_approvals = false
      for _, line in ipairs(lines) do
        if line:find("Approvals:") then found_approvals = true end
      end
      assert.is_false(found_approvals, "no approvals line should appear for empty approved_by")
    end)
  end)
end)
