-- Stub vim global for busted (no Neovim runtime).
-- Must set _G.vim so required modules can see it, then alias the spec's
-- local _ENV.vim to the same table so that mutations in tests are visible
-- to the module at call time.
_G.vim = _G.vim or { notify = function() end }
vim = _G.vim

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

  describe("setup overrides", function()
    it("overrides key with string", function()
      keymaps.setup({ next_file = "<Tab>" })
      assert.equals("<Tab>", keymaps.get("next_file"))
      assert.equals("[f", keymaps.get("prev_file"))
    end)

    it("disables key with false", function()
      keymaps.setup({ approve = false })
      assert.is_false(keymaps.get("approve"))
    end)

    it("warns on unknown action", function()
      local warned = false
      local orig = vim.notify
      vim.notify = function(msg)
        if msg:match("Unknown keymap action") then warned = true end
      end
      keymaps.setup({ bogus_action = "x" })
      vim.notify = orig
      assert.is_true(warned)
    end)
  end)

  describe("get", function()
    it("returns nil for nonexistent action", function()
      keymaps.setup()
      assert.is_nil(keymaps.get("nonexistent"))
    end)

    it("lazy-inits if setup not called", function()
      assert.equals("]f", keymaps.get("next_file"))
    end)
  end)
end)
