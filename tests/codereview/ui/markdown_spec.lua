local markdown = require("codereview.ui.markdown")

describe("parse_inline", function()
  it("returns plain text unchanged", function()
    local segs = markdown.parse_inline("hello world", "CodeReviewComment")
    assert.same({ { "hello world", "CodeReviewComment" } }, segs)
  end)

  it("parses bold **text**", function()
    local segs = markdown.parse_inline("a **bold** b", "CodeReviewComment")
    assert.same({
      { "a ", "CodeReviewComment" },
      { "bold", "CodeReviewCommentBold" },
      { " b", "CodeReviewComment" },
    }, segs)
  end)

  it("parses italic *text*", function()
    local segs = markdown.parse_inline("a *italic* b", "CodeReviewComment")
    assert.same({
      { "a ", "CodeReviewComment" },
      { "italic", "CodeReviewCommentItalic" },
      { " b", "CodeReviewComment" },
    }, segs)
  end)

  it("parses inline `code`", function()
    local segs = markdown.parse_inline("run `foo()` now", "CodeReviewComment")
    assert.same({
      { "run ", "CodeReviewComment" },
      { "foo()", "CodeReviewCommentCode" },
      { " now", "CodeReviewComment" },
    }, segs)
  end)

  it("parses ~~strikethrough~~", function()
    local segs = markdown.parse_inline("a ~~old~~ b", "CodeReviewComment")
    assert.same({
      { "a ", "CodeReviewComment" },
      { "old", "CodeReviewCommentStrikethrough" },
      { " b", "CodeReviewComment" },
    }, segs)
  end)

  it("parses [link](url)", function()
    local segs = markdown.parse_inline("see [docs](http://x.com) here", "CodeReviewComment")
    assert.same({
      { "see ", "CodeReviewComment" },
      { "docs", "CodeReviewCommentLink" },
      { " here", "CodeReviewComment" },
    }, segs)
  end)

  it("handles unresolved base highlight", function()
    local segs = markdown.parse_inline("**bold**", "CodeReviewCommentUnresolved")
    assert.same({
      { "bold", "CodeReviewCommentBoldUnresolved" },
    }, segs)
  end)

  it("ignores markdown inside code spans", function()
    local segs = markdown.parse_inline("`**not bold**`", "CodeReviewComment")
    assert.same({
      { "**not bold**", "CodeReviewCommentCode" },
    }, segs)
  end)

  it("treats unclosed delimiters as literal text", function()
    local segs = markdown.parse_inline("a **unclosed", "CodeReviewComment")
    assert.same({ { "a **unclosed", "CodeReviewComment" } }, segs)
  end)

  it("treats empty delimiters as literal text", function()
    local segs = markdown.parse_inline("a **** b", "CodeReviewComment")
    assert.same({ { "a **** b", "CodeReviewComment" } }, segs)
  end)

  it("handles multiple formats in one line", function()
    local segs = markdown.parse_inline("**bold** and *italic*", "CodeReviewComment")
    assert.same({
      { "bold", "CodeReviewCommentBold" },
      { " and ", "CodeReviewComment" },
      { "italic", "CodeReviewCommentItalic" },
    }, segs)
  end)
end)

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

  it("to_lines preserves markdown links", function()
    local lines = markdown.to_lines("see [docs](http://x.com) here")
    assert.equals("see [docs](http://x.com) here", lines[1])
  end)
end)
