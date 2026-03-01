local commits_comp = require("codereview.mr.sidebar_components.commits")

describe("sidebar commits component", function()
  it("renders nothing when no commits", function()
    local state = { commits = {}, commit_filter = nil }
    local lines, row_map = {}, {}
    commits_comp.render(state, lines, row_map, 40)
    assert.equals(0, #lines)
  end)

  it("renders commit titles with section header", function()
    local state = {
      commits = {
        { sha = "sha1", title = "Fix login redirect", author = "alice" },
        { sha = "sha2", title = "Add rate limiting", author = "bob" },
      },
      commit_filter = nil,
    }
    local lines, row_map = {}, {}
    commits_comp.render(state, lines, row_map, 40)
    assert.truthy(lines[1]:match("Commits"))
    assert.truthy(lines[2]:match("Fix login redirect"))
    assert.truthy(lines[3]:match("Add rate limiting"))
  end)

  it("marks active commit with bullet", function()
    local state = {
      commits = {
        { sha = "sha1", title = "First" },
        { sha = "sha2", title = "Second" },
      },
      commit_filter = { to_sha = "sha2", label = "Second" },
    }
    local lines, row_map = {}, {}
    commits_comp.render(state, lines, row_map, 40)
    assert.truthy(lines[3]:match("●"))
    assert.falsy(lines[2]:match("●"))
  end)

  it("adds row_map entries for each commit", function()
    local state = {
      commits = {
        { sha = "sha1", title = "First" },
        { sha = "sha2", title = "Second" },
      },
      commit_filter = nil,
    }
    local lines, row_map = {}, {}
    commits_comp.render(state, lines, row_map, 40)
    assert.equals("commit", row_map[2].type)
    assert.equals("sha1", row_map[2].sha)
    assert.equals("commit", row_map[3].type)
    assert.equals("sha2", row_map[3].sha)
  end)

  it("truncates long titles to fit width", function()
    local state = {
      commits = { { sha = "sha1", title = "This is a very long commit message that should be truncated to fit" } },
      commit_filter = nil,
    }
    local lines, row_map = {}, {}
    commits_comp.render(state, lines, row_map, 30)
    assert.is_true(#lines[2] <= 30)
  end)

  it("defaults collapsed when > 8 commits", function()
    local commits = {}
    for i = 1, 10 do table.insert(commits, { sha = "sha" .. i, title = "Commit " .. i }) end
    local state = { commits = commits, commit_filter = nil, collapsed_commits = nil }
    local lines, row_map = {}, {}
    commits_comp.render(state, lines, row_map, 40)
    assert.truthy(lines[1]:match("▸"))
    assert.equals(2, #lines) -- header + blank separator only
  end)

  it("adds since-last-review row when last_reviewed_sha is set", function()
    local state = {
      commits = {
        { sha = "sha1", title = "First" },
        { sha = "sha2", title = "Second" },
      },
      commit_filter = nil,
      last_reviewed_sha = "sha1",
      review = { head_sha = "sha2" },
    }
    local lines, row_map = {}, {}
    commits_comp.render(state, lines, row_map, 40)
    local found = false
    for _, line in ipairs(lines) do
      if line:match("Since last review") then found = true end
    end
    assert.is_true(found)
  end)
end)
