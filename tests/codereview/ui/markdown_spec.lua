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

  -- Flanking rules tests
  it("rejects bold inside word boundaries (no flanking)", function()
    -- 2**3 should not be bold
    local segs = markdown.parse_inline("2**3 = 8 and 3**2 = 9", "CodeReviewComment")
    assert.same({ { "2**3 = 8 and 3**2 = 9", "CodeReviewComment" } }, segs)
  end)

  it("rejects italic with leading/trailing whitespace in inner text", function()
    local segs = markdown.parse_inline("a * b * c", "CodeReviewComment")
    assert.same({ { "a * b * c", "CodeReviewComment" } }, segs)
  end)

  it("rejects italic inside word boundaries", function()
    local segs = markdown.parse_inline("a*b*c", "CodeReviewComment")
    assert.same({ { "a*b*c", "CodeReviewComment" } }, segs)
  end)

  it("accepts bold preceded by punctuation", function()
    local segs = markdown.parse_inline("(**bold**)", "CodeReviewComment")
    assert.same({
      { "(", "CodeReviewComment" },
      { "bold", "CodeReviewCommentBold" },
      { ")", "CodeReviewComment" },
    }, segs)
  end)

  it("accepts italic at start of line", function()
    local segs = markdown.parse_inline("*italic* text", "CodeReviewComment")
    assert.same({
      { "italic", "CodeReviewCommentItalic" },
      { " text", "CodeReviewComment" },
    }, segs)
  end)

  it("rejects bold with inner text starting with space", function()
    local segs = markdown.parse_inline("** not bold **", "CodeReviewComment")
    assert.same({ { "** not bold **", "CodeReviewComment" } }, segs)
  end)

  it("rejects strikethrough inside word boundaries", function()
    local segs = markdown.parse_inline("a~~b~~c", "CodeReviewComment")
    assert.same({ { "a~~b~~c", "CodeReviewComment" } }, segs)
  end)

  it("renders bold around code spans", function()
    local segs = markdown.parse_inline("**Missing `code` here.**", "CodeReviewComment")
    assert.same({
      { "Missing ", "CodeReviewCommentBold" },
      { "code", "CodeReviewCommentCode" },
      { " here.", "CodeReviewCommentBold" },
    }, segs)
  end)

  it("renders bold around multiple code spans", function()
    local segs = markdown.parse_inline("**use `foo` and `bar`**", "CodeReviewComment")
    assert.same({
      { "use ", "CodeReviewCommentBold" },
      { "foo", "CodeReviewCommentCode" },
      { " and ", "CodeReviewCommentBold" },
      { "bar", "CodeReviewCommentCode" },
    }, segs)
  end)

  it("renders bold with code span and unresolved hl", function()
    local segs = markdown.parse_inline("**check `val`**", "CodeReviewCommentUnresolved")
    assert.same({
      { "check ", "CodeReviewCommentBoldUnresolved" },
      { "val", "CodeReviewCommentCodeUnresolved" },
    }, segs)
  end)
end)

describe("find_spans", function()
  it("returns empty for plain text", function()
    assert.same({}, markdown.find_spans("hello world"))
  end)

  it("finds bold span positions", function()
    local spans = markdown.find_spans("a **bold** b")
    assert.same({ { 3, 10 } }, spans)
  end)

  it("finds multiple span positions", function()
    local spans = markdown.find_spans("**bold** and *italic*")
    assert.equals(2, #spans)
  end)
end)

describe("segments_to_extmarks", function()
  it("returns plain text and no highlights for unmarked text", function()
    local segs = { { "hello world", "CodeReviewComment" } }
    local text, hls = markdown.segments_to_extmarks(segs, 5, "CodeReviewComment")
    assert.equals("hello world", text)
    assert.same({}, hls)
  end)

  it("strips bold delimiters and returns highlight extmark", function()
    local segs = markdown.parse_inline("a **bold** b", "CodeReviewComment")
    local text, hls = markdown.segments_to_extmarks(segs, 3, "CodeReviewComment")
    assert.equals("a bold b", text)
    assert.same({ { 3, 2, 6, "CodeReviewCommentBold" } }, hls)
  end)

  it("handles code span", function()
    local segs = markdown.parse_inline("run `foo()` now", "CodeReviewComment")
    local text, hls = markdown.segments_to_extmarks(segs, 0, "CodeReviewComment")
    assert.equals("run foo() now", text)
    assert.same({ { 0, 4, 9, "CodeReviewCommentCode" } }, hls)
  end)

  it("handles multiple formats", function()
    local segs = markdown.parse_inline("**bold** and *italic*", "CodeReviewComment")
    local text, hls = markdown.segments_to_extmarks(segs, 0, "CodeReviewComment")
    assert.equals("bold and italic", text)
    assert.equals(2, #hls)
    assert.same({ 0, 0, 4, "CodeReviewCommentBold" }, hls[1])
    assert.same({ 0, 9, 15, "CodeReviewCommentItalic" }, hls[2])
  end)

  it("returns empty for empty segments", function()
    local text, hls = markdown.segments_to_extmarks({}, 0, "CodeReviewComment")
    assert.equals("", text)
    assert.same({}, hls)
  end)
end)

describe("highlight.setup block-level groups", function()
  it("defines CodeReviewMdH1 through H6", function()
    local highlight = require("codereview.ui.highlight")
    highlight.setup()
    for i = 1, 6 do
      local hl = vim.api.nvim_get_hl(0, { name = "CodeReviewMdH" .. i })
      assert.is_not_nil(hl, "CodeReviewMdH" .. i .. " should be defined")
    end
  end)

  it("defines CodeReviewMdCodeBlock", function()
    local highlight = require("codereview.ui.highlight")
    highlight.setup()
    local hl = vim.api.nvim_get_hl(0, { name = "CodeReviewMdCodeBlock" })
    assert.is_not_nil(hl)
  end)

  it("defines CodeReviewMdBlockquote", function()
    local highlight = require("codereview.ui.highlight")
    highlight.setup()
    local hl = vim.api.nvim_get_hl(0, { name = "CodeReviewMdBlockquote" })
    assert.is_not_nil(hl)
  end)

  it("defines CodeReviewMdBlockquoteBorder", function()
    local highlight = require("codereview.ui.highlight")
    highlight.setup()
    local hl = vim.api.nvim_get_hl(0, { name = "CodeReviewMdBlockquoteBorder" })
    assert.is_not_nil(hl)
  end)

  it("defines CodeReviewMdTableHeader", function()
    local highlight = require("codereview.ui.highlight")
    highlight.setup()
    local hl = vim.api.nvim_get_hl(0, { name = "CodeReviewMdTableHeader" })
    assert.is_not_nil(hl)
  end)

  it("defines CodeReviewMdTableBorder", function()
    local highlight = require("codereview.ui.highlight")
    highlight.setup()
    local hl = vim.api.nvim_get_hl(0, { name = "CodeReviewMdTableBorder" })
    assert.is_not_nil(hl)
  end)

  it("defines CodeReviewMdHr", function()
    local highlight = require("codereview.ui.highlight")
    highlight.setup()
    local hl = vim.api.nvim_get_hl(0, { name = "CodeReviewMdHr" })
    assert.is_not_nil(hl)
  end)

  it("defines CodeReviewMdListBullet", function()
    local highlight = require("codereview.ui.highlight")
    highlight.setup()
    local hl = vim.api.nvim_get_hl(0, { name = "CodeReviewMdListBullet" })
    assert.is_not_nil(hl)
  end)
end)

describe("parse_blocks", function()
  it("returns struct with lines, highlights, code_blocks", function()
    local result = markdown.parse_blocks("hello", "CodeReviewComment")
    assert.is_table(result.lines)
    assert.is_table(result.highlights)
    assert.is_table(result.code_blocks)
  end)

  it("passes plain text through with inline markdown", function()
    local result = markdown.parse_blocks("**bold** text", "CodeReviewComment")
    assert.equals(1, #result.lines)
    assert.equals("bold text", result.lines[1])
    assert.equals(1, #result.highlights)
    assert.same({ 0, 0, 4, "CodeReviewCommentBold" }, result.highlights[1])
  end)

  it("handles multiline paragraphs", function()
    local result = markdown.parse_blocks("line one\nline two", "CodeReviewComment")
    assert.equals(2, #result.lines)
    assert.equals("line one", result.lines[1])
    assert.equals("line two", result.lines[2])
  end)

  it("handles nil input", function()
    local result = markdown.parse_blocks(nil, "CodeReviewComment")
    assert.same({}, result.lines)
    assert.same({}, result.highlights)
    assert.same({}, result.code_blocks)
  end)

  it("handles empty string input", function()
    local result = markdown.parse_blocks("", "CodeReviewComment")
    assert.same({}, result.lines)
    assert.same({}, result.highlights)
    assert.same({}, result.code_blocks)
  end)

  it("preserves blank lines between paragraphs", function()
    local result = markdown.parse_blocks("para one\n\npara two", "CodeReviewComment")
    assert.equals(3, #result.lines)
    assert.equals("para one", result.lines[1])
    assert.equals("", result.lines[2])
    assert.equals("para two", result.lines[3])
  end)
end)

describe("parse_blocks header rendering", function()
  it("renders H1 with CodeReviewMdH1 highlight", function()
    local result = markdown.parse_blocks("# Title", "CodeReviewComment")
    assert.equals(1, #result.lines)
    assert.equals("Title", result.lines[1])
    assert.equals(1, #result.highlights)
    assert.same({ 0, 0, 5, "CodeReviewMdH1" }, result.highlights[1])
  end)

  it("renders H3 with CodeReviewMdH3 highlight", function()
    local result = markdown.parse_blocks("### Sub", "CodeReviewComment")
    assert.equals(1, #result.lines)
    assert.equals("Sub", result.lines[1])
    assert.equals(1, #result.highlights)
    assert.same({ 0, 0, 3, "CodeReviewMdH3" }, result.highlights[1])
  end)

  it("renders header with inline markdown overlay", function()
    local result = markdown.parse_blocks("## **Bold** title", "CodeReviewComment")
    assert.equals(1, #result.lines)
    assert.equals("Bold title", result.lines[1])
    assert.equals(2, #result.highlights)
    assert.same({ 0, 0, 10, "CodeReviewMdH2" }, result.highlights[1])
    assert.same({ 0, 0, 4, "CodeReviewCommentBold" }, result.highlights[2])
  end)

  it("does not treat # inside text as header", function()
    local result = markdown.parse_blocks("issue #42 is fixed", "CodeReviewComment")
    assert.equals(1, #result.lines)
    assert.equals("issue #42 is fixed", result.lines[1])
    assert.same({}, result.highlights)
  end)
end)

describe("parse_blocks ordered lists", function()
  it("renders numbered list items", function()
    local r = markdown.parse_blocks("1. first\n2. second\n3. third", "CodeReviewComment", {})
    assert.equals(3, #r.lines)
    assert.equals("1. first", r.lines[1])
    assert.equals("2. second", r.lines[2])
    assert.equals("3. third", r.lines[3])
  end)

  it("parses inline markdown in ordered list items", function()
    local r = markdown.parse_blocks("1. **bold** item", "CodeReviewComment", {})
    assert.equals("1. bold item", r.lines[1])
  end)

  it("handles nested ordered lists", function()
    local r = markdown.parse_blocks("1. top\n   1. nested", "CodeReviewComment", {})
    assert.equals(2, #r.lines)
    assert.equals("1. top", r.lines[1])
    assert.equals("   1. nested", r.lines[2])
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
