local gitlab = require("codereview.providers.gitlab")

describe("providers.gitlab", function()
  it("has name = gitlab", function()
    assert.equal("gitlab", gitlab.name)
  end)

  describe("normalize_mr", function()
    it("maps GitLab MR fields to normalized review", function()
      local mr = {
        iid = 42, title = "Fix bug",
        author = { username = "alice" },
        source_branch = "fix/bug", target_branch = "main",
        state = "opened",
        diff_refs = { base_sha = "aaa", head_sha = "bbb", start_sha = "ccc" },
        web_url = "https://gitlab.com/mr/42", description = "desc",
        head_pipeline = { status = "success" },
        approved_by = { { user = { username = "bob" } } },
        approvals_before_merge = 1, sha = "bbb",
      }
      local r = gitlab.normalize_mr(mr)
      assert.equal(42, r.id)
      assert.equal("alice", r.author)
      assert.equal("aaa", r.base_sha)
      assert.equal("ccc", r.start_sha)
      assert.equal("success", r.pipeline_status)
      assert.equal("bob", r.approved_by[1])
    end)
  end)

  describe("normalize_discussion", function()
    it("maps GitLab discussion to normalized discussion", function()
      local disc = {
        id = "disc-1",
        notes = { {
          id = 100, author = { username = "alice" },
          body = "looks good", created_at = "2026-01-01T00:00:00Z",
          system = false, resolvable = true, resolved = false,
          resolved_by = { username = "bob" },
          position = { new_path = "foo.lua", old_path = "foo.lua", new_line = 10, old_line = nil },
        } },
      }
      local d = gitlab.normalize_discussion(disc)
      assert.equal("alice", d.notes[1].author)
      assert.equal("bob", d.notes[1].resolved_by)
      assert.equal("foo.lua", d.notes[1].position.path)
    end)

    it("preserves position SHAs from raw.position", function()
      local disc = {
        id = "disc-2",
        notes = { {
          id = 101, author = { username = "alice" },
          body = "comment", created_at = "2026-01-01T00:00:00Z",
          system = false, resolvable = true, resolved = false,
          position = {
            new_path = "bar.lua", old_path = "bar.lua", new_line = 5, old_line = nil,
            base_sha = "abc123", head_sha = "def456", start_sha = "ghi789",
          },
        } },
      }
      local d = gitlab.normalize_discussion(disc)
      local pos = d.notes[1].position
      assert.equal("abc123", pos.base_sha)
      assert.equal("def456", pos.head_sha)
      assert.equal("ghi789", pos.start_sha)
    end)

    it("preserves change_position when present", function()
      local disc = {
        id = "disc-3",
        notes = { {
          id = 102, author = { username = "alice" },
          body = "outdated", created_at = "2026-01-01T00:00:00Z",
          system = false, resolvable = true, resolved = false,
          position = { new_path = "baz.lua", old_path = "baz.lua", new_line = 8, old_line = nil,
            base_sha = "aaa", head_sha = "bbb", start_sha = "ccc" },
          change_position = { new_path = "baz.lua", old_path = "baz_old.lua", new_line = 8, old_line = 7 },
        } },
      }
      local d = gitlab.normalize_discussion(disc)
      local cp = d.notes[1].change_position
      assert.is_not_nil(cp)
      assert.equal("baz.lua", cp.new_path)
      assert.equal("baz_old.lua", cp.old_path)
      assert.equal(8, cp.new_line)
      assert.equal(7, cp.old_line)
    end)

    it("sets change_position to nil when absent", function()
      local disc = {
        id = "disc-4",
        notes = { {
          id = 103, author = { username = "alice" },
          body = "current", created_at = "2026-01-01T00:00:00Z",
          system = false, resolvable = true, resolved = false,
          position = { new_path = "qux.lua", old_path = "qux.lua", new_line = 3, old_line = nil,
            base_sha = "aaa", head_sha = "bbb", start_sha = "ccc" },
        } },
      }
      local d = gitlab.normalize_discussion(disc)
      assert.is_nil(d.notes[1].change_position)
    end)
  end)

  describe("build_auth_header", function()
    it("uses PRIVATE-TOKEN for pat", function()
      assert.equal("tok123", gitlab.build_auth_header("tok123", "pat")["PRIVATE-TOKEN"])
    end)
    it("uses Bearer for oauth", function()
      assert.equal("Bearer tok123", gitlab.build_auth_header("tok123", "oauth")["Authorization"])
    end)
  end)

  describe("parse_next_page", function()
    it("reads x-next-page header", function()
      assert.equal(3, gitlab.parse_next_page({ ["x-next-page"] = "3" }))
    end)
    it("returns nil for empty", function()
      assert.is_nil(gitlab.parse_next_page({ ["x-next-page"] = "" }))
    end)
  end)

  describe("get_current_user", function()
    before_each(function()
      package.loaded["codereview.api.auth"] = {
        get_token = function() return "glpat-test", "pat" end,
      }
      gitlab._cached_user = nil
    end)

    after_each(function()
      package.loaded["codereview.api.auth"] = nil
      gitlab._cached_user = nil
    end)

    it("returns username from /api/v4/user endpoint", function()
      local mock_client = {
        get = function(_, path, _)
          assert.equals("/api/v4/user", path)
          return { status = 200, data = { username = "testuser" } }
        end,
      }
      local user, err = gitlab.get_current_user(mock_client, { base_url = "https://gitlab.com" })
      assert.is_nil(err)
      assert.equals("testuser", user)
    end)

    it("caches result after first call", function()
      local call_count = 0
      local mock_client = {
        get = function(_, _, _)
          call_count = call_count + 1
          return { status = 200, data = { username = "cached" } }
        end,
      }
      local ctx = { base_url = "https://gitlab.com" }
      gitlab.get_current_user(mock_client, ctx)
      gitlab.get_current_user(mock_client, ctx)
      assert.equals(1, call_count)
    end)
  end)

  describe("create_draft_comment", function()
    it("exists as a function", function()
      assert.is_function(gitlab.create_draft_comment)
    end)
  end)

  describe("publish_review", function()
    it("exists as a function", function()
      assert.is_function(gitlab.publish_review)
    end)
  end)

  describe("create_review", function()
    it("exists as a function", function()
      assert.is_function(gitlab.create_review)
    end)
  end)

  describe("edit_note", function()
    before_each(function()
      package.loaded["codereview.api.auth"] = {
        get_token = function() return "glpat-test", "pat" end,
      }
    end)
    after_each(function()
      package.loaded["codereview.api.auth"] = nil
    end)

    it("PUTs to discussions/:disc_id/notes/:note_id with new body", function()
      local put_url, put_body
      local mock_client = {
        put = function(_, path, opts)
          put_url = path
          put_body = opts.body
          return { status = 200, body = vim.json.encode({ id = 5, body = "updated" }) }
        end,
      }
      local ctx = { base_url = "https://gitlab.com", project = "owner/repo" }
      local review = { id = 10 }
      local result, err = gitlab.edit_note(mock_client, ctx, review, "disc1", 5, "updated")
      assert.is_nil(err)
      assert.truthy(put_url:find("/discussions/disc1/notes/5"))
      assert.equals("updated", put_body.body)
    end)
  end)

  describe("delete_note", function()
    before_each(function()
      package.loaded["codereview.api.auth"] = {
        get_token = function() return "glpat-test", "pat" end,
      }
    end)
    after_each(function()
      package.loaded["codereview.api.auth"] = nil
    end)

    it("DELETEs discussions/:disc_id/notes/:note_id", function()
      local deleted_url
      local mock_client = {
        delete = function(_, path, _)
          deleted_url = path
          return { status = 204 }
        end,
      }
      local ctx = { base_url = "https://gitlab.com", project = "owner/repo" }
      local review = { id = 10 }
      local result, err = gitlab.delete_note(mock_client, ctx, review, "disc1", 5)
      assert.is_nil(err)
      assert.truthy(deleted_url:find("/discussions/disc1/notes/5"))
    end)
  end)
end)
