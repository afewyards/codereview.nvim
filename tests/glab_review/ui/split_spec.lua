local split = require("glab_review.ui.split")

describe("ui.split", function()
  it("creates sidebar and main pane", function()
    local layout = split.create({ sidebar_width = 30 })
    assert.truthy(layout.sidebar_buf)
    assert.truthy(layout.main_buf)
    assert.truthy(layout.sidebar_win)
    assert.truthy(layout.main_win)

    -- Cleanup
    split.close(layout)
  end)
end)
