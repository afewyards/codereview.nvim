local keymaps = require("codereview.keymaps")

describe("keymaps", function()
  before_each(function()
    keymaps.reset()
  end)

  describe("defaults", function()
    it("has all 26 actions", function()
      keymaps.setup()
      local all = keymaps.get_all()
      assert.equals("]f", all.next_file.key)
      assert.equals("n", all.next_file.mode)
      assert.equals("[f", all.prev_file.key)
      assert.equals("cc", all.create_comment.key)
      assert.equals("v", all.create_range_comment.mode)
      assert.equals("q", all.quit.key)
      local count = 0
      for _ in pairs(all) do count = count + 1 end
      assert.equals(26, count)
    end)
  end)
end)
