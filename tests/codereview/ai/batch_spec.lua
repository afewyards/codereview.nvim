local batch = require("codereview.ai.batch")

describe("batch.build", function()
  it("packs by char budget", function()
    local diffs = {}
    for i = 1, 5 do
      diffs[i] = { new_path = "f" .. i, diff = string.rep("x", 30) }
    end
    local out = batch.build(diffs, { char_budget = 100, max_files = 99 })
    assert.are.equal(2, #out)
    assert.are.equal(3, #out[1])
    assert.are.equal(2, #out[2])
  end)

  it("oversize file goes alone", function()
    local diffs = {
      { new_path = "s", diff = string.rep("x", 10) },
      { new_path = "huge", diff = string.rep("x", 500) },
      { new_path = "t", diff = string.rep("x", 5) },
    }
    local out = batch.build(diffs, { char_budget = 100, max_files = 99 })
    assert.are.equal(3, #out)
    assert.are.equal("huge", out[2][1].new_path)
  end)

  it("respects max_files cap", function()
    local diffs = {}
    for i = 1, 20 do
      diffs[i] = { new_path = "f" .. i, diff = "x" }
    end
    local out = batch.build(diffs, { char_budget = 1e9, max_files = 5 })
    assert.are.equal(4, #out)
    assert.are.equal(5, #out[1])
  end)

  it("single file returns single batch", function()
    local diffs = { { new_path = "a.lua", diff = "@@\n+line" } }
    local out = batch.build(diffs, { char_budget = 80000, max_files = 15 })
    assert.are.equal(1, #out)
    assert.are.equal(1, #out[1])
    assert.are.equal("a.lua", out[1][1].new_path)
  end)

  it("empty diffs returns empty batches", function()
    local out = batch.build({}, { char_budget = 80000, max_files = 15 })
    assert.are.equal(0, #out)
  end)

  it("uses defaults when opts omitted", function()
    local diffs = {}
    for i = 1, 3 do
      diffs[i] = { new_path = "f" .. i, diff = "x" }
    end
    -- Should not error; all fit in one batch with generous defaults
    local out = batch.build(diffs, nil)
    assert.are.equal(1, #out)
    assert.are.equal(3, #out[1])
  end)
end)
