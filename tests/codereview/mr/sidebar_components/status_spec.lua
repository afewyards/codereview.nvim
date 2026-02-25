local function make_status()
  package.loaded["codereview.mr.sidebar_components.status"] = nil
  return require("codereview.mr.sidebar_components.status")
end

describe("sidebar_components.status", function()
  after_each(function()
    package.loaded["codereview.review.session"] = nil
    package.loaded["codereview.mr.sidebar_components.status"] = nil
  end)

  it("returns empty result when session is inactive", function()
    package.loaded["codereview.review.session"] = {
      get = function() return { active = false } end,
    }
    local status = make_status()
    local result = status.render({}, 30)
    assert.same({}, result.lines)
    assert.same({}, result.highlights)
    assert.same({}, result.row_map)
  end)

  it("shows review in progress when session active and no AI pending", function()
    package.loaded["codereview.review.session"] = {
      get = function()
        return { active = true, ai_pending = false, ai_total = 0, ai_completed = 0 }
      end,
    }
    local status = make_status()
    local state = { local_drafts = {}, ai_suggestions = nil, discussions = {} }
    local result = status.render(state, 30)
    assert.equals("● Review in progress", result.lines[1])
    assert.equals(1, result.row_map.status)
    -- status row highlight should be CodeReviewFileAdded
    local found = false
    for _, hl in ipairs(result.highlights) do
      if hl.row == 1 and hl.line_hl == "CodeReviewFileAdded" then
        found = true
      end
    end
    assert.is_true(found, "expected CodeReviewFileAdded highlight on status row")
  end)

  it("shows AI reviewing with progress when ai_pending", function()
    package.loaded["codereview.review.session"] = {
      get = function()
        return { active = true, ai_pending = true, ai_completed = 3, ai_total = 5 }
      end,
    }
    local status = make_status()
    local state = { local_drafts = {}, ai_suggestions = nil, discussions = {} }
    local result = status.render(state, 30)
    assert.equals("⟳ AI reviewing… 3/5", result.lines[1])
    -- spinner highlight
    local found = false
    for _, hl in ipairs(result.highlights) do
      if hl.row == 1 and hl.line_hl == "CodeReviewSpinner" then
        found = true
      end
    end
    assert.is_true(found, "expected CodeReviewSpinner highlight on status row")
  end)
end)
