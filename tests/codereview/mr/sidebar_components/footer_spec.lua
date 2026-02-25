local footer = require("codereview.mr.sidebar_components.footer")

describe("sidebar_components.footer", function()
  it("returns 3 lines: separator, progress, right-aligned help hint", function()
    local state = {
      files = { { new_path = "a.lua" }, { new_path = "b.lua" } },
      file_review_status = { ["a.lua"] = { status = "reviewed" } },
      discussions = {},
    }
    local lines, hls = footer.build(state, 30)
    assert.equals(3, #lines)
    -- line 1: full-width separator (equality check avoids multi-byte pattern issue)
    assert.equals(string.rep("─", 30), lines[1])
    -- line 2: progress counts
    assert.truthy(lines[2]:find("1/2 reviewed"), "expected '1/2 reviewed' in: " .. lines[2])
    assert.truthy(lines[2]:find("0 unresolved"), "expected '0 unresolved' in: " .. lines[2])
    -- line 3: right-aligned help hint
    assert.truthy(lines[3]:find("? help"), "expected '? help' in: " .. lines[3])
    -- lines 1 and 2 have CodeReviewProgressDim highlight
    assert.equals(2, #hls)
    assert.equals(1, hls[1].row)
    assert.equals("CodeReviewProgressDim", hls[1].line_hl)
    assert.equals(2, hls[2].row)
    assert.equals("CodeReviewProgressDim", hls[2].line_hl)
  end)

  it("counts only non-draft unresolved discussions", function()
    local state = {
      files = {},
      file_review_status = {},
      discussions = {
        { local_draft = false, resolved = false },  -- unresolved: counts
        { local_draft = true,  resolved = false },  -- local draft: skip
        { local_draft = false, resolved = true  },  -- resolved: skip
      },
    }
    local lines = footer.build(state, 30)
    assert.truthy(lines[2]:find("1 unresolved"), "expected '1 unresolved' in: " .. lines[2])
    assert.truthy(lines[2]:find("0/0 reviewed"), "expected '0/0 reviewed' in: " .. lines[2])
  end)
end)
