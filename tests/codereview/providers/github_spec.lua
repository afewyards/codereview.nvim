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

  describe("normalize_graphql_threads", function()
    it("maps GraphQL reviewThread nodes to discussion shape", function()
      local threads = {
        {
          id = "PRRT_abc123",
          isResolved = true,
          diffSide = "RIGHT",
          startDiffSide = nil,
          comments = { nodes = {
            { databaseId = 1, author = { login = "alice" }, body = "root comment",
              createdAt = "2026-01-01T00:00:00Z", path = "foo.lua", line = 10,
              startLine = nil, commit = { oid = "sha123" } },
            { databaseId = 2, author = { login = "bob" }, body = "reply",
              createdAt = "2026-01-01T00:01:00Z", path = "foo.lua", line = 10,
              startLine = nil, commit = { oid = "sha123" } },
          }},
        },
      }
      local discussions = github.normalize_graphql_threads(threads)
      assert.equal(1, #discussions)
      assert.equal("1", discussions[1].id)
      assert.equal("PRRT_abc123", discussions[1].node_id)
      assert.is_true(discussions[1].resolved)
      assert.equal(2, #discussions[1].notes)
      assert.equal("alice", discussions[1].notes[1].author)
      assert.equal("bob", discussions[1].notes[2].author)
      assert.equal("foo.lua", discussions[1].notes[1].position.new_path)
      assert.equal(10, discussions[1].notes[1].position.new_line)
    end)

    it("handles thread with no comments gracefully", function()
      local threads = { { id = "PRRT_empty", isResolved = false, comments = { nodes = {} } } }
      local discussions = github.normalize_graphql_threads(threads)
      assert.equal(0, #discussions)
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
      -- Stub plenary.curl to prevent real HTTP calls
      package.loaded["plenary.curl"] = {
        request = function()
          return { status = 200, body = vim.json.encode({ data = { repository = { pullRequest = { reviewThreads = { nodes = {} } } } } }) }
        end,
      }
    end)

    after_each(function()
      package.loaded["codereview.api.auth"] = nil
      package.loaded["plenary.curl"] = nil
    end)

    it("resolve_discussion returns error when thread not found", function()
      local result, err = github.resolve_discussion(make_client({}), ctx, review, "1", true)
      assert.is_nil(result)
      assert.truthy(err:find("thread"))
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

    it("get_discussions fetches threads via GraphQL", function()
      -- Use raw JSON strings to avoid vim.json.encode array/object issues in test env
      local body = '{"data":{"repository":{"pullRequest":{"reviewThreads":'
        .. '{"pageInfo":{"hasNextPage":false,"endCursor":null},'
        .. '"nodes":[{"id":"PRRT_1","isResolved":false,"diffSide":"RIGHT","startDiffSide":null,"comments":{"nodes":['
        .. '{"databaseId":1,"author":{"login":"a"},"body":"root",'
        .. '"createdAt":"2026-01-01T00:00:00Z","path":"f.lua","line":5,'
        .. '"startLine":null,'
        .. '"commit":{"oid":"abc"}}]}}]}}}}}}'
      package.loaded["plenary.curl"] = {
        request = function() return { status = 200, body = body } end,
      }
      local discs, err = github.get_discussions(make_client({}), ctx, review)
      assert.is_nil(err)
      assert.equal(1, #discs)
      assert.equal("1", discs[1].id)
      assert.equal("PRRT_1", discs[1].node_id)
    end)

    it("get_discussions paginates when hasNextPage is true", function()
      -- Use raw JSON strings to avoid vim.json.encode array/object issues in test env
      local page1 = '{"data":{"repository":{"pullRequest":{"reviewThreads":'
        .. '{"pageInfo":{"hasNextPage":true,"endCursor":"cursor1"},'
        .. '"nodes":[{"id":"PRRT_1","isResolved":false,"diffSide":"RIGHT","startDiffSide":null,"comments":{"nodes":['
        .. '{"databaseId":1,"author":{"login":"a"},"body":"first",'
        .. '"createdAt":"2026-01-01T00:00:00Z","path":"a.lua","line":1,'
        .. '"startLine":null,'
        .. '"commit":{"oid":"abc"}}]}}]}}}}}}'
      local page2 = '{"data":{"repository":{"pullRequest":{"reviewThreads":'
        .. '{"pageInfo":{"hasNextPage":false,"endCursor":"cursor2"},'
        .. '"nodes":[{"id":"PRRT_2","isResolved":true,"diffSide":"RIGHT","startDiffSide":null,"comments":{"nodes":['
        .. '{"databaseId":2,"author":{"login":"b"},"body":"second",'
        .. '"createdAt":"2026-01-01T00:01:00Z","path":"b.lua","line":5,'
        .. '"startLine":null,'
        .. '"commit":{"oid":"def"}}]}}]}}}}}}'
      local call_count = 0
      package.loaded["plenary.curl"] = {
        request = function()
          call_count = call_count + 1
          return { status = 200, body = call_count == 1 and page1 or page2 }
        end,
      }
      local discs, err = github.get_discussions(make_client({}), ctx, review)
      assert.is_nil(err)
      assert.equal(2, #discs)
      assert.equal(2, call_count)
      assert.equal("1", discs[1].id)
      assert.equal("2", discs[2].id)
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

    it("resolve_discussion uses node_id to skip lookup query", function()
      local mutations = {}
      package.loaded["plenary.curl"] = {
        request = function(params)
          local body = vim.json.decode(params.body)
          table.insert(mutations, body.query)
          return {
            status = 200,
            body = vim.json.encode({ data = { resolveReviewThread = { thread = { id = "PRRT_1", isResolved = true } } } }),
          }
        end,
      }
      local result, err = github.resolve_discussion(make_client({}), ctx, review, "1", true, "PRRT_1")
      assert.is_nil(err)
      assert.truthy(result)
      -- Should only have made ONE GraphQL call (the mutation), not two (lookup + mutation)
      assert.equal(1, #mutations)
      assert.truthy(mutations[1]:find("resolveReviewThread"))
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
