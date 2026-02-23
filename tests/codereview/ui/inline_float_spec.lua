local inline_float = require("codereview.ui.inline_float")

describe("inline_float", function()
  describe("build_context_header", function()
    it("returns code line for comment action", function()
      local lines = inline_float.build_context_header({
        action_type = "comment",
        context_text = "local x = 1",
      })
      assert.equals(1, #lines)
      assert.truthy(lines[1]:find("local x = 1"))
    end)

    it("returns author prefix for reply action", function()
      local lines = inline_float.build_context_header({
        action_type = "reply",
        context_text = "@alice: some comment text here",
      })
      assert.equals(1, #lines)
      assert.truthy(lines[1]:find("@alice"))
    end)

    it("returns edit label for edit action", function()
      local lines = inline_float.build_context_header({
        action_type = "edit",
        context_text = "Editing comment on line 42",
      })
      assert.equals(1, #lines)
      assert.truthy(lines[1]:find("Editing"))
    end)

    it("returns empty for no context", function()
      local lines = inline_float.build_context_header({})
      assert.equals(0, #lines)
    end)
  end)

  describe("compute_height", function()
    it("clamps to min 3", function()
      assert.equals(3, inline_float.compute_height(0, 1))
    end)

    it("clamps to max 15", function()
      assert.equals(15, inline_float.compute_height(20, 1))
    end)

    it("adds header lines to content lines", function()
      assert.equals(6, inline_float.compute_height(5, 1))
    end)
  end)

  describe("border_hl", function()
    it("returns reply border for reply type", function()
      assert.equals("CodeReviewReplyBorder", inline_float.border_hl("reply"))
    end)

    it("returns edit border for edit type", function()
      assert.equals("CodeReviewEditBorder", inline_float.border_hl("edit"))
    end)

    it("returns comment border for nil", function()
      assert.equals("CodeReviewCommentBorder", inline_float.border_hl(nil))
    end)

    it("returns comment border for comment type", function()
      assert.equals("CodeReviewCommentBorder", inline_float.border_hl("comment"))
    end)
  end)
end)
