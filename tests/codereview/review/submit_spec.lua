-- tests/codereview/review/submit_spec.lua
local submit = require("codereview.review.submit")

describe("review.submit", function()
  describe("filter_accepted", function()
    it("returns only accepted and edited suggestions", function()
      local suggestions = {
        { comment = "a", status = "accepted" },
        { comment = "b", status = "pending" },
        { comment = "c", status = "edited" },
        { comment = "d", status = "deleted" },
      }
      local accepted = submit.filter_accepted(suggestions)
      assert.equals(2, #accepted)
      assert.equals("a", accepted[1].comment)
      assert.equals("c", accepted[2].comment)
    end)

    it("returns empty for no accepted", function()
      local accepted = submit.filter_accepted({
        { comment = "a", status = "pending" },
      })
      assert.equals(0, #accepted)
    end)
  end)
end)
