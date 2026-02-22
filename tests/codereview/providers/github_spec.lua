-- tests/codereview/providers/github_spec.lua
local github = require("codereview.providers.github")

describe("providers.github", function()
  it("has name = github", function()
    assert.equal("github", github.name)
  end)

  describe("normalize_pr", function()
    it("maps GitHub PR fields to normalized review", function()
      local pr = {
        number = 99, title = "Add feature",
        user = { login = "bob" },
        head = { ref = "feat/x", sha = "bbb" },
        base = { ref = "main", sha = "aaa" },
        state = "open",
        html_url = "https://github.com/owner/repo/pull/99",
        body = "description",
      }
      local r = github.normalize_pr(pr)
      assert.equal(99, r.id)
      assert.equal("bob", r.author)
      assert.equal("aaa", r.base_sha)
      assert.equal("aaa", r.start_sha)  -- GitHub: start_sha = base_sha
      assert.equal("feat/x", r.source_branch)
    end)
  end)

  describe("normalize_review_comments_to_discussions", function()
    it("groups by in_reply_to_id and sorts by created_at", function()
      local comments = {
        { id = 2, user = { login = "b" }, body = "reply", created_at = "2026-01-01T00:01:00Z",
          path = "foo.lua", line = 10, side = "RIGHT", commit_id = "abc", in_reply_to_id = 1 },
        { id = 1, user = { login = "a" }, body = "first", created_at = "2026-01-01T00:00:00Z",
          path = "foo.lua", line = 10, side = "RIGHT", commit_id = "abc", in_reply_to_id = nil },
      }
      local discussions = github.normalize_review_comments_to_discussions(comments)
      assert.equal(1, #discussions)
      assert.equal(2, #discussions[1].notes)
      assert.equal("a", discussions[1].notes[1].author)
      assert.equal("b", discussions[1].notes[2].author)
    end)
  end)

  describe("build_auth_header", function()
    it("uses Authorization Bearer", function()
      assert.equal("Bearer ghp_123", github.build_auth_header("ghp_123")["Authorization"])
    end)
  end)

  describe("parse_next_page", function()
    it("extracts next URL from Link header", function()
      local headers = {
        link = '<https://api.github.com/repos/o/r/pulls?page=3>; rel="next", <https://api.github.com/repos/o/r/pulls?page=5>; rel="last"',
      }
      assert.equal("https://api.github.com/repos/o/r/pulls?page=3", github.parse_next_page(headers))
    end)
    it("returns nil when no next", function()
      assert.is_nil(github.parse_next_page({ link = '<url>; rel="last"' }))
    end)
  end)
end)
