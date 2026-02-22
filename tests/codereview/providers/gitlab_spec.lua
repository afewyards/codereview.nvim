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
end)
