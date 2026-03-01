local ansi = require("codereview.pipeline.ansi")

describe("pipeline.ansi", function()
  it("strips plain text without escapes", function()
    local result = ansi.parse("hello world")
    assert.equal(1, #result.lines)
    assert.equal("hello world", result.lines[1])
    assert.equal(0, #result.highlights)
  end)

  it("strips basic SGR codes and returns highlights", function()
    local result = ansi.parse("\27[32mgreen text\27[0m normal")
    assert.equal(1, #result.lines)
    assert.equal("green text normal", result.lines[1])
    assert.truthy(#result.highlights > 0)
    local hl = result.highlights[1]
    assert.equal(1, hl.line)
    assert.equal(0, hl.col_start)
    assert.equal(10, hl.col_end) -- "green text" = 10 chars
  end)

  it("handles multiple lines", function()
    local result = ansi.parse("line1\nline2\nline3")
    assert.equal(3, #result.lines)
    assert.equal("line1", result.lines[1])
    assert.equal("line3", result.lines[3])
  end)

  it("handles bold SGR", function()
    local result = ansi.parse("\27[1mbold\27[0m")
    assert.equal("bold", result.lines[1])
    assert.truthy(#result.highlights > 0)
  end)

  it("handles 8-bit colors", function()
    local result = ansi.parse("\27[38;5;196mred\27[0m")
    assert.equal("red", result.lines[1])
    assert.truthy(#result.highlights > 0)
  end)

  it("handles 24-bit RGB colors", function()
    local result = ansi.parse("\27[38;2;255;0;0mred\27[0m")
    assert.equal("red", result.lines[1])
    assert.truthy(#result.highlights > 0)
  end)

  it("handles nested/stacked SGR codes", function()
    local result = ansi.parse("\27[1;31mbold red\27[0m")
    assert.equal("bold red", result.lines[1])
    assert.truthy(#result.highlights > 0)
  end)

  it("handles empty input", function()
    local result = ansi.parse("")
    assert.equal(1, #result.lines)
    assert.equal("", result.lines[1])
  end)

  it("strips non-SGR escape sequences", function()
    -- Cursor movement, title set, etc.
    local result = ansi.parse("\27[2J\27]0;title\7visible text")
    assert.equal("visible text", result.lines[1])
  end)
end)
