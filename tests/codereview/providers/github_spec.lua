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

    it("sets GitHub-specific headers", function()
      local h = github.build_auth_header("tok")
      assert.equal("application/vnd.github+json", h["Accept"])
      assert.equal("2022-11-28", h["X-GitHub-Api-Version"])
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

  describe("provider interface signatures", function()
    -- Verify that all interface methods exist and accept the unified (client, ctx, review, ...) pattern.
    -- We pass mock objects; we do not make real HTTP calls.
    local function make_client(stub)
      return setmetatable({}, { __index = function(_, k) return stub[k] or function() return nil, "stub" end end })
    end

    local ctx = { base_url = "https://api.github.com", project = "owner/repo", host = "github.com", platform = "github" }
    local review = { id = 42, sha = "deadbeef", base_sha = "aaa", head_sha = "bbb", start_sha = "aaa" }

    before_each(function()
      -- Stub auth so no env var is needed
      package.loaded["codereview.api.auth"] = {
        get_token = function() return "ghp_test", "pat" end,
      }
    end)

    after_each(function()
      package.loaded["codereview.api.auth"] = nil
    end)

    it("resolve_discussion returns nil, not supported", function()
      local result, err = github.resolve_discussion(make_client({}), ctx, review, "1", true)
      assert.is_nil(result)
      assert.equal("not supported", err)
    end)

    it("unapprove returns nil, not supported", function()
      local result, err = github.unapprove(make_client({}), ctx, review)
      assert.is_nil(result)
      assert.equal("not supported", err)
    end)

    it("get_review calls client.get and normalizes", function()
      local called_path
      local client = make_client({
        get = function(_, path, _)
          called_path = path
          return { data = {
            number = 42, title = "T", user = { login = "u" },
            head = { ref = "br", sha = "hhh" }, base = { ref = "main", sha = "bbb" },
            state = "open", html_url = "https://github.com/o/r/pull/42", body = "",
          } }, nil
        end,
      })
      local r, err = github.get_review(client, ctx, 42)
      assert.is_nil(err)
      assert.equal("/repos/owner/repo/pulls/42", called_path)
      assert.equal(42, r.id)
    end)

    it("get_diffs calls client.get and normalizes files", function()
      local called_path
      local client = make_client({
        get = function(_, path, _)
          called_path = path
          return { data = {
            { filename = "new.lua", status = "added", patch = "@@ ...", previous_filename = nil },
            { filename = "old.lua", previous_filename = "orig.lua", status = "renamed", patch = "" },
          } }, nil
        end,
      })
      local diffs, err = github.get_diffs(client, ctx, review)
      assert.is_nil(err)
      assert.equal("/repos/owner/repo/pulls/42/files", called_path)
      assert.equal(2, #diffs)
      assert.equal("new.lua", diffs[1].new_path)
      assert.is_true(diffs[1].new_file)
      assert.equal("orig.lua", diffs[2].old_path)
      assert.is_true(diffs[2].renamed_file)
    end)

    it("get_discussions calls paginate_all_url and normalizes", function()
      local called_url
      local client = make_client({
        paginate_all_url = function(url, _)
          called_url = url
          return {
            { id = 1, user = { login = "a" }, body = "root", created_at = "2026-01-01T00:00:00Z",
              path = "f.lua", line = 5, side = "RIGHT", commit_id = "abc", in_reply_to_id = nil },
          }
        end,
      })
      local discs, err = github.get_discussions(client, ctx, review)
      assert.is_nil(err)
      assert.truthy(called_url:find("/repos/owner/repo/pulls/42/comments"))
      assert.equal(1, #discs)
    end)

    it("post_comment inline posts to pulls comments endpoint", function()
      local called_path
      local client = make_client({
        post = function(_, path, _) called_path = path return {}, nil end,
      })
      local position = { new_path = "foo.lua", new_line = 10, side = "RIGHT", commit_sha = "abc" }
      github.post_comment(client, ctx, review, "body text", position)
      assert.equal("/repos/owner/repo/pulls/42/comments", called_path)
    end)

    it("post_comment general posts to issues comments endpoint", function()
      local called_path
      local client = make_client({
        post = function(_, path, _) called_path = path return {}, nil end,
      })
      github.post_comment(client, ctx, review, "general comment", nil)
      assert.equal("/repos/owner/repo/issues/42/comments", called_path)
    end)

    it("reply_to_discussion posts to replies endpoint", function()
      local called_path
      local client = make_client({
        post = function(_, path, _) called_path = path return {}, nil end,
      })
      github.reply_to_discussion(client, ctx, review, "99", "reply body")
      assert.equal("/repos/owner/repo/pulls/42/comments/99/replies", called_path)
    end)

    it("close patches PR with state=closed", function()
      local called_path, called_body
      local client = make_client({
        patch = function(_, path, opts) called_path = path called_body = opts.body return {}, nil end,
      })
      github.close(client, ctx, review)
      assert.equal("/repos/owner/repo/pulls/42", called_path)
      assert.equal("closed", called_body.state)
    end)

    it("approve posts APPROVE review", function()
      local called_path, called_body
      local client = make_client({
        post = function(_, path, opts) called_path = path called_body = opts.body return {}, nil end,
      })
      github.approve(client, ctx, review)
      assert.equal("/repos/owner/repo/pulls/42/reviews", called_path)
      assert.equal("APPROVE", called_body.event)
    end)

    it("merge puts with merge_method=merge by default", function()
      local called_path, called_body
      local client = make_client({
        put = function(_, path, opts) called_path = path called_body = opts.body return {}, nil end,
      })
      github.merge(client, ctx, review, {})
      assert.equal("/repos/owner/repo/pulls/42/merge", called_path)
      assert.equal("merge", called_body.merge_method)
    end)

    it("merge uses squash when opts.squash=true", function()
      local called_body
      local client = make_client({
        put = function(_, _, opts) called_body = opts.body return {}, nil end,
      })
      github.merge(client, ctx, review, { squash = true })
      assert.equal("squash", called_body.merge_method)
    end)
  end)

  describe("create_draft_comment", function()
    it("accumulates comments in _pending_comments", function()
      github._pending_comments = {} -- reset
      local review = { id = 1, sha = "abc123" }
      github.create_draft_comment(nil, nil, review, { body = "Fix this", path = "foo.lua", line = 10 })
      github.create_draft_comment(nil, nil, review, { body = "And this", path = "bar.lua", line = 20 })
      assert.equals(2, #github._pending_comments)
      assert.equals("Fix this", github._pending_comments[1].body)
      assert.equals("foo.lua", github._pending_comments[1].path)
      github._pending_comments = {} -- cleanup
    end)
  end)

  describe("publish_review", function()
    it("exists as a function", function()
      assert.is_function(github.publish_review)
    end)
  end)

  describe("create_review", function()
    it("exists as a function", function()
      assert.is_function(github.create_review)
    end)
  end)
end)
