local log_view = require("codereview.pipeline.log_view")

describe("pipeline.log_view", function()
  it("exports open and close functions", function()
    assert.is_function(log_view.open)
    assert.is_function(log_view.close)
  end)
end)
