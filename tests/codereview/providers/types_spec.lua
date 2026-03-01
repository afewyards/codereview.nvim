local types = require("codereview.providers.types")

describe("providers.types", function()
  describe("normalize_review", function()
    it("passes through normalized data", function()
      local input = {
        id = 42, title = "Fix bug", author = "alice",
        source_branch = "fix/bug", target_branch = "main",
        state = "open", base_sha = "aaa", head_sha = "bbb",
        start_sha = "ccc",
        web_url = "https://example.com/pr/42", description = "desc",
        pipeline_status = nil, approved_by = {}, approvals_required = 0,
      }
      local r = types.normalize_review(input)
      assert.equal(42, r.id)
      assert.equal("alice", r.author)
      assert.equal("ccc", r.start_sha)
    end)

    it("preserves merge_status field", function()
      local raw = { id = 1, title = "Test", merge_status = "can_be_merged" }
      local review = types.normalize_review(raw)
      assert.equals("can_be_merged", review.merge_status)
    end)

    it("defaults merge_status to nil", function()
      local raw = { id = 1, title = "Test" }
      local review = types.normalize_review(raw)
      assert.is_nil(review.merge_status)
    end)
  end)

  describe("normalize_discussion", function()
    it("normalizes a discussion with notes", function()
      local input = {
        id = "disc-1", resolved = false,
        notes = { {
          id = "n1", author = "bob", body = "comment",
          created_at = "2026-01-01T00:00:00Z",
          system = false, resolvable = true, resolved = false,
          position = { path = "foo.lua", new_line = 10, old_line = nil, side = "right" },
        } },
      }
      local d = types.normalize_discussion(input)
      assert.equal("disc-1", d.id)
      assert.equal("bob", d.notes[1].author)
    end)
  end)

  describe("normalize_file_diff", function()
    it("normalizes file diff entry", function()
      local f = types.normalize_file_diff({
        diff = "@@ -1 +1,2 @@\n old\n+new",
        new_path = "foo.lua", old_path = "foo.lua",
        renamed_file = false, new_file = false, deleted_file = false,
      })
      assert.equal("foo.lua", f.new_path)
    end)
  end)

  describe("normalize_pipeline", function()
    it("normalizes pipeline data with defaults", function()
      local p = types.normalize_pipeline({
        id = 123, status = "running", ref = "main", sha = "abc",
        web_url = "https://example.com/pipeline/123",
        created_at = "2026-01-01", updated_at = "2026-01-02",
        duration = 120,
      })
      assert.equal(123, p.id)
      assert.equal("running", p.status)
      assert.equal("main", p.ref)
      assert.equal("abc", p.sha)
      assert.equal(120, p.duration)
    end)

    it("defaults missing fields", function()
      local p = types.normalize_pipeline({ id = 1 })
      assert.equal("unknown", p.status)
      assert.equal("", p.ref)
      assert.equal("", p.web_url)
      assert.equal(0, p.duration)
    end)
  end)

  describe("normalize_pipeline_job", function()
    it("normalizes job data", function()
      local j = types.normalize_pipeline_job({
        id = 456, name = "test", stage = "test", status = "success",
        duration = 60, web_url = "https://example.com/job/456",
        allow_failure = false, started_at = "2026-01-01", finished_at = "2026-01-02",
      })
      assert.equal(456, j.id)
      assert.equal("test", j.name)
      assert.equal("test", j.stage)
      assert.equal(60, j.duration)
      assert.is_false(j.allow_failure)
    end)

    it("defaults missing fields", function()
      local j = types.normalize_pipeline_job({ id = 1 })
      assert.equal("", j.name)
      assert.equal("", j.stage)
      assert.equal("unknown", j.status)
      assert.equal(0, j.duration)
      assert.is_false(j.allow_failure)
    end)
  end)
end)
