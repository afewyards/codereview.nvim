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

describe("bulk_publish", function()
  it("passes opts to provider.publish_review", function()
    local captured_opts
    package.loaded["codereview.providers"] = {
      detect = function()
        return {
          publish_review = function(_, _, _, opts) captured_opts = opts return {}, nil end,
        }, { base_url = "test" }, nil
      end,
    }
    package.loaded["codereview.api.client"] = {}
    package.loaded["codereview.review.submit"] = nil
    local s = require("codereview.review.submit")
    s.bulk_publish({ id = 1 }, { body = "LGTM", event = "APPROVE" })
    assert.equal("LGTM", captured_opts.body)
    assert.equal("APPROVE", captured_opts.event)
  end)
end)
