local endpoints = require("glab_review.api.endpoints")

describe("endpoints", function()
  it("builds MR list path", function()
    local path = endpoints.mr_list("group%2Fproject")
    assert.equals("/projects/group%2Fproject/merge_requests", path)
  end)

  it("builds MR detail path", function()
    local path = endpoints.mr_detail("group%2Fproject", 42)
    assert.equals("/projects/group%2Fproject/merge_requests/42", path)
  end)

  it("builds MR diffs path", function()
    local path = endpoints.mr_diffs("group%2Fproject", 42)
    assert.equals("/projects/group%2Fproject/merge_requests/42/diffs", path)
  end)

  it("builds discussions path", function()
    local path = endpoints.discussions("group%2Fproject", 42)
    assert.equals("/projects/group%2Fproject/merge_requests/42/discussions", path)
  end)

  it("builds draft notes path", function()
    local path = endpoints.draft_notes("group%2Fproject", 42)
    assert.equals("/projects/group%2Fproject/merge_requests/42/draft_notes", path)
  end)

  it("builds pipeline jobs path", function()
    local path = endpoints.pipeline_jobs("group%2Fproject", 999)
    assert.equals("/projects/group%2Fproject/pipelines/999/jobs", path)
  end)
end)
