-- Stub vim global for busted (no Neovim runtime).
-- Must set _G.vim so required modules can see it, then alias the spec's
-- local _ENV.vim to the same table so that mutations in tests are visible
-- to the module at call time.
local function _deep_copy(orig)
  local copy = {}
  for k, v in pairs(orig) do
    copy[k] = type(v) == "table" and _deep_copy(v) or v
  end
  return copy
end
_G.vim = _G.vim or { notify = function() end, deepcopy = _deep_copy }
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
      assert.equals("Q", all.quit.key)
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

  describe("full config flow", function()
    it("setup via config propagates to keymaps", function()
      local config = require("codereview.config")
      config.setup({ keymaps = { next_file = "<Tab>", approve = false } })
      assert.equals("<Tab>", keymaps.get("next_file"))
      assert.is_false(keymaps.get("approve"))
      assert.equals("Q", keymaps.get("quit"))
      config.reset()
    end)
  end)

  describe("apply", function()
    local orig_keymap
    local orig_tbl_extend

    before_each(function()
      orig_keymap = vim.keymap
      orig_tbl_extend = vim.tbl_extend
      vim.tbl_extend = function(_, a, b)
        local t = {}
        for k, v in pairs(a) do t[k] = v end
        for k, v in pairs(b) do t[k] = v end
        return t
      end
    end)

    after_each(function()
      vim.keymap = orig_keymap
      vim.tbl_extend = orig_tbl_extend
    end)

    it("combines callbacks that share the same key+mode", function()
      keymaps.setup()
      local called = {}
      local registered_fn
      vim.keymap = { set = function(_, _, fn) registered_fn = fn end }

      keymaps.apply(0, {
        accept_suggestion = function() table.insert(called, "accept") end,
        approve = function() table.insert(called, "approve") end,
      })

      assert.is_not_nil(registered_fn)
      registered_fn()
      table.sort(called)
      assert.same({ "accept", "approve" }, called)
    end)

    it("registers a single callback directly without a wrapper", function()
      keymaps.setup()
      local orig_fn = function() end
      local registered_fns = {}
      vim.keymap = { set = function(_, key, fn) registered_fns[key] = fn end }

      keymaps.apply(0, {
        quit = orig_fn,
      })

      assert.equals(orig_fn, registered_fns["Q"])
    end)
  end)
end)
