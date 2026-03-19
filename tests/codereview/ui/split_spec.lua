local split = require("codereview.ui.split")
local config = require("codereview.config")

describe("ui.split", function()
  before_each(function()
    config.setup({ open_in_tab = false })
  end)

  after_each(function()
    config.reset()
  end)

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
