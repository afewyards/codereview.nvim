local pipeline = require("codereview.pipeline")

describe("pipeline.init", function()
  it("exports open, close, is_open", function()
    assert.is_function(pipeline.open)
    assert.is_function(pipeline.close)
    assert.is_function(pipeline.is_open)
  end)

  it("is_open returns false initially", function()
    assert.is_false(pipeline.is_open())
  end)
end)
