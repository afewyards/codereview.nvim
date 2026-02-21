local markdown = require("glab_review.ui.markdown")

describe("ui.markdown", function()
  it("renders plain text lines", function()
    local lines = markdown.to_lines("Hello world\nSecond line")
    assert.equals(2, #lines)
    assert.equals("Hello world", lines[1])
    assert.equals("Second line", lines[2])
  end)

  it("preserves code blocks", function()
    local text = "Before\n```lua\nlocal x = 1\n```\nAfter"
    local lines = markdown.to_lines(text)
    assert.equals(5, #lines)
    assert.equals("```lua", lines[2])
  end)

  it("converts bullet lists", function()
    local text = "- item one\n- item two"
    local lines = markdown.to_lines(text)
    assert.equals(2, #lines)
  end)
end)
