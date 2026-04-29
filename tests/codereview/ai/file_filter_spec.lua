local filter = require("codereview.ai.file_filter")

describe("file_filter", function()
  it("skips lockfiles", function()
    local out = filter.apply({
      { new_path = "src/foo.lua", diff = "" },
      { new_path = "package-lock.json", diff = "" },
      { new_path = "Cargo.lock", diff = "" },
      { new_path = "pnpm-lock.yaml", diff = "" },
    }, nil)
    assert.are.equal(1, #out)
  end)

  it("skips minified, maps, vendored", function()
    local out = filter.apply({
      { new_path = "x.min.js", diff = "" },
      { new_path = "x.css.map", diff = "" },
      { new_path = "node_modules/x/y.js", diff = "" },
      { new_path = "ok.js", diff = "" },
    }, nil)
    assert.are.equal(1, #out)
  end)

  it("skips binary diffs", function()
    local out = filter.apply({
      { new_path = "img.png", diff = "diff --git a/img.png b/img.png\nBinary files differ" },
      { new_path = "ok.lua", diff = "@@" },
    }, nil)
    assert.are.equal(1, #out)
  end)

  it("user patterns additive", function()
    local out = filter.apply({ { new_path = "x.json", diff = "" }, { new_path = "ok.lua", diff = "" } }, { "*.json" })
    assert.are.equal(1, #out)
  end)

  it("nil path skipped", function()
    local out = filter.apply({ { new_path = nil, old_path = nil, diff = "" } }, nil)
    assert.are.equal(0, #out)
  end)
end)
