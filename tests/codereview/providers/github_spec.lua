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

    it("falls back to originalLine when line is nil (outdated comment)", function()
      local threads = { {
        id = "PRRT_outdated", isResolved = false, isOutdated = true,
        diffSide = "RIGHT", startDiffSide = nil,
        comments = { nodes = { {
          databaseId = 10, author = { login = "alice" },
          body = "old feedback", createdAt = "2026-01-01T00:00:00Z",
          path = "foo.lua", line = vim.NIL, originalLine = 20,
          startLine = vim.NIL, originalStartLine = vim.NIL,
          outdated = true, commit = { oid = "old-sha" },
        } } },
      } }
      local discussions = github.normalize_graphql_threads(threads)
      assert.equal(20, discussions[1].notes[1].position.new_line)
      assert.is_true(discussions[1].notes[1].position.outdated)
    end)

    it("sets outdated=false for current comments", function()
      local threads = { {
        id = "PRRT_current", isResolved = false, isOutdated = false,
        diffSide = "RIGHT", startDiffSide = nil,
        comments = { nodes = { {
          databaseId = 11, author = { login = "bob" },
          body = "current", createdAt = "2026-01-01T00:00:00Z",
          path = "bar.lua", line = 5, originalLine = 5,
          startLine = vim.NIL, originalStartLine = vim.NIL,
          outdated = false, commit = { oid = "cur-sha" },
        } } },
      } }
      local discussions = github.normalize_graphql_threads(threads)
      assert.equal(5, discussions[1].notes[1].position.new_line)
      assert.is_false(discussions[1].notes[1].position.outdated)
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

    it("get_diffs calls client.paginate_all_url and normalizes files", function()
      local called_url
      local client = make_client({
        paginate_all_url = function(url, _)
          called_url = url
          return {
            { filename = "new.lua", status = "added", patch = "@@ ...", previous_filename = nil },
            { filename = "old.lua", previous_filename = "orig.lua", status = "renamed", patch = "" },
          }
        end,
      })
      local diffs, err = github.get_diffs(client, ctx, review)
      assert.is_nil(err)
      assert.equal("https://api.github.com/repos/owner/repo/pulls/42/files", called_url)
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

  describe("get_current_user", function()
    before_each(function()
      package.loaded["codereview.api.auth"] = {
        get_token = function() return "ghp_test", "pat" end,
      }
      github._cached_user = nil
    end)

    after_each(function()
      package.loaded["codereview.api.auth"] = nil
      github._cached_user = nil
    end)

    it("returns login from /user endpoint", function()
      local mock_client = {
        get = function(_, path, _)
          assert.equals("/user", path)
          return { status = 200, data = { login = "testuser" } }
        end,
      }
      local user, err = github.get_current_user(mock_client, { base_url = "https://api.github.com" })
      assert.is_nil(err)
      assert.equals("testuser", user)
    end)

    it("caches result after first call", function()
      local call_count = 0
      local mock_client = {
        get = function(_, _, _)
          call_count = call_count + 1
          return { status = 200, data = { login = "cached" } }
        end,
      }
      local ctx = { base_url = "https://api.github.com" }
      github.get_current_user(mock_client, ctx)
      github.get_current_user(mock_client, ctx)
      assert.equals(1, call_count)
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

  describe("edit_note", function()
    before_each(function()
      package.loaded["codereview.api.auth"] = {
        get_token = function() return "ghp_test", "pat" end,
      }
    end)
    after_each(function()
      package.loaded["codereview.api.auth"] = nil
    end)

    it("PATCHes the comment with new body", function()
      local patched_url, patched_body
      local mock_client = {
        patch = function(_, path, opts)
          patched_url = path
          patched_body = opts.body
          return { status = 200, body = vim.json.encode({ id = 42, body = "updated" }) }
        end,
      }
      local ctx = { base_url = "https://api.github.com", project = "owner/repo" }
      local review = { id = 1 }
      local result, err = github.edit_note(mock_client, ctx, review, "disc_ignored", 42, "updated")
      assert.is_nil(err)
      assert.truthy(patched_url:find("/pulls/comments/42"))
      assert.equals("updated", patched_body.body)
    end)
  end)

  describe("delete_note", function()
    before_each(function()
      package.loaded["codereview.api.auth"] = {
        get_token = function() return "ghp_test", "pat" end,
      }
    end)
    after_each(function()
      package.loaded["codereview.api.auth"] = nil
    end)

    it("DELETEs the comment", function()
      local deleted_url
      local mock_client = {
        delete = function(_, path, _)
          deleted_url = path
          return { status = 204 }
        end,
      }
      local ctx = { base_url = "https://api.github.com", project = "owner/repo" }
      local review = { id = 1 }
      local result, err = github.delete_note(mock_client, ctx, review, "disc_ignored", 42)
      assert.is_nil(err)
      assert.truthy(deleted_url:find("/pulls/comments/42"))
    end)
  end)
end)

describe("get_pending_review_drafts", function()
  before_each(function()
    package.loaded["codereview.api.auth"] = {
      get_token = function() return "ghp_test", "pat" end,
    }
    github._pending_review_id = nil
  end)
  after_each(function()
    package.loaded["codereview.api.auth"] = nil
    github._pending_review_id = nil
  end)

  it("finds PENDING review and normalizes its comments", function()
    local mock_client = {
      get = function(_, path, _)
        if path:find("/reviews$") then
          return { data = {
            { id = 100, state = "APPROVED", user = { login = "bob" } },
            { id = 200, state = "PENDING", user = { login = "alice" } },
          } }
        elseif path:find("/reviews/200/comments") then
          return { data = {
            { id = 1, body = "fix this", path = "foo.lua", line = 10, side = "RIGHT",
              created_at = "2026-01-01T00:00:00Z", user = { login = "alice" } },
          } }
        end
      end,
    }
    local ctx = { base_url = "https://api.github.com", project = "owner/repo" }
    local review = { id = 42 }
    local drafts, err = github.get_pending_review_drafts(mock_client, ctx, review)
    assert.is_nil(err)
    assert.equal(1, #drafts)
    assert.is_true(drafts[1].is_draft)
    assert.equal("You (draft)", drafts[1].notes[1].author)
    assert.equal("fix this", drafts[1].notes[1].body)
    assert.equal(200, github._pending_review_id)
  end)

  it("returns empty when no PENDING review exists", function()
    local mock_client = {
      get = function(_, path, _)
        if path:find("/reviews$") then
          return { data = { { id = 100, state = "APPROVED" } } }
        end
      end,
    }
    local ctx = { base_url = "https://api.github.com", project = "owner/repo" }
    local drafts = github.get_pending_review_drafts(mock_client, ctx, { id = 1 })
    assert.equal(0, #drafts)
    assert.is_nil(github._pending_review_id)
  end)

  it("does not set _pending_review_id when PENDING review has zero comments", function()
    local mock_client = {
      get = function(_, path, _)
        if path:find("/reviews$") then
          return { data = { { id = 200, state = "PENDING" } } }
        elseif path:find("/reviews/200/comments") then
          return { data = {} }
        end
      end,
    }
    local ctx = { base_url = "https://api.github.com", project = "owner/repo" }
    local drafts = github.get_pending_review_drafts(mock_client, ctx, { id = 1 })
    assert.equal(0, #drafts)
    assert.is_nil(github._pending_review_id)
  end)
end)

describe("discard_pending_review", function()
  before_each(function()
    package.loaded["codereview.api.auth"] = {
      get_token = function() return "ghp_test", "pat" end,
    }
    github._pending_review_id = 200
  end)
  after_each(function()
    package.loaded["codereview.api.auth"] = nil
    github._pending_review_id = nil
  end)

  it("DELETEs the pending review and clears _pending_review_id", function()
    local deleted_url
    local mock_client = {
      delete = function(_, path, _)
        deleted_url = path
        return { status = 200 }
      end,
    }
    local ctx = { base_url = "https://api.github.com", project = "owner/repo" }
    github.discard_pending_review(mock_client, ctx, { id = 42 })
    assert.truthy(deleted_url:find("/reviews/200"))
    assert.is_nil(github._pending_review_id)
  end)

  it("returns nil when no pending review", function()
    github._pending_review_id = nil
    local mock_client = { delete = function() error("should not be called") end }
    local ctx = { base_url = "https://api.github.com", project = "owner/repo" }
    local _, err = github.discard_pending_review(mock_client, ctx, { id = 1 })
    assert.truthy(err:find("No pending"))
  end)
end)

describe("publish_review with pending review", function()
  before_each(function()
    package.loaded["codereview.api.auth"] = {
      get_token = function() return "ghp_test", "pat" end,
    }
    github._pending_comments = {}
    github._pending_review_id = nil
  end)
  after_each(function()
    package.loaded["codereview.api.auth"] = nil
    github._pending_comments = {}
    github._pending_review_id = nil
  end)

  it("submits existing pending review before publishing new comments", function()
    github._pending_review_id = 200
    github._pending_comments = { { body = "new", path = "bar.lua", line = 5, side = "RIGHT" } }
    local posted_paths = {}
    local mock_client = {
      post = function(_, path, opts)
        table.insert(posted_paths, path)
        return { data = {} }, nil
      end,
    }
    local ctx = { base_url = "https://api.github.com", project = "owner/repo" }
    github.publish_review(mock_client, ctx, { id = 42, sha = "abc" })
    -- Should have two POSTs: submit existing review, then new review
    assert.equal(2, #posted_paths)
    assert.truthy(posted_paths[1]:find("/reviews/200/events"))
    assert.truthy(posted_paths[2]:find("/reviews$"))
    assert.is_nil(github._pending_review_id)
  end)

  it("submits only existing pending review when no new comments", function()
    github._pending_review_id = 200
    local posted_paths = {}
    local mock_client = {
      post = function(_, path, _)
        table.insert(posted_paths, path)
        return { data = {} }, nil
      end,
    }
    local ctx = { base_url = "https://api.github.com", project = "owner/repo" }
    github.publish_review(mock_client, ctx, { id = 42, sha = "abc" })
    assert.equal(1, #posted_paths)
    assert.truthy(posted_paths[1]:find("/reviews/200/events"))
  end)
end)
