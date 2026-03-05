local actions = require("codereview.mr.actions")
local providers = require("codereview.providers")

describe("mr.actions", function()
  local mock_provider
  local mock_ctx
  local mock_client

  before_each(function()
    mock_ctx = { project = "group/repo", base_url = "https://gitlab.com" }
    mock_client = {}

    mock_provider = {
      approve = spy.new(function()
        return { ok = true }, nil
      end),
      unapprove = spy.new(function()
        return { ok = true }, nil
      end),
      merge = spy.new(function()
        return { ok = true }, nil
      end),
      close = spy.new(function()
        return { ok = true }, nil
      end),
    }

    stub(providers, "detect").returns(mock_provider, mock_ctx, nil)

    -- stub plenary.async so run() executes its callback synchronously
    package.loaded["plenary.async"] = {
      run = function(fn)
        fn()
      end,
    }

    -- stub async_client so provider receives our mock_client
    package.loaded["codereview.api.async_client"] = mock_client

    -- stub vim.schedule to execute immediately
    _G._original_vim_schedule = vim.schedule
    vim.schedule = function(fn)
      fn()
    end
  end)

  after_each(function()
    providers.detect:revert()
    package.loaded["plenary.async"] = nil
    package.loaded["codereview.api.async_client"] = nil
    vim.schedule = _G._original_vim_schedule
    _G._original_vim_schedule = nil
  end)

  describe("approve", function()
    it("calls provider.approve with client, ctx, and review", function()
      local review = { iid = 1, sha = "abc" }
      actions.approve(review)
      assert.spy(mock_provider.approve).was_called_with(mock_client, mock_ctx, review)
    end)

    it("notifies with error when detect fails", function()
      providers.detect:revert()
      stub(providers, "detect").returns(nil, nil, "no remote")
      local notified_msg
      vim.notify = function(msg)
        notified_msg = msg
      end
      actions.approve({})
      assert.equals("no remote", notified_msg)
    end)
  end)

  describe("unapprove", function()
    it("calls provider.unapprove with client, ctx, and review", function()
      local review = { iid = 2 }
      actions.unapprove(review)
      assert.spy(mock_provider.unapprove).was_called_with(mock_client, mock_ctx, review)
    end)

    it("calls vim.notify with WARN when provider returns an error", function()
      mock_provider.unapprove = spy.new(function()
        return nil, "unapprove failed"
      end)
      local notified_msg, notified_level
      _G.vim = _G.vim or {}
      _G.vim.notify = function(msg, level)
        notified_msg = msg
        notified_level = level
      end
      _G.vim.log = _G.vim.log or {}
      _G.vim.log.levels = _G.vim.log.levels or { WARN = 3 }

      actions.unapprove({ iid = 2 })
      assert.equals("unapprove failed", notified_msg)
      assert.equals(vim.log.levels.WARN, notified_level)
    end)
  end)

  describe("merge", function()
    it("calls provider.merge with client, ctx, review, and opts", function()
      local review = { iid = 3 }
      local opts = { squash = true }
      actions.merge(review, opts)
      assert.spy(mock_provider.merge).was_called_with(mock_client, mock_ctx, review, opts)
    end)

    it("notifies with error when detect fails", function()
      providers.detect:revert()
      stub(providers, "detect").returns(nil, nil, "no remote")
      local notified_msg
      vim.notify = function(msg)
        notified_msg = msg
      end
      actions.merge({}, {})
      assert.equals("no remote", notified_msg)
    end)
  end)

  describe("close", function()
    it("calls provider.close with client, ctx, and review", function()
      local review = { iid = 4 }
      actions.close(review)
      assert.spy(mock_provider.close).was_called_with(mock_client, mock_ctx, review)
    end)

    it("notifies with error when detect fails", function()
      providers.detect:revert()
      stub(providers, "detect").returns(nil, nil, "no remote")
      local notified_msg
      vim.notify = function(msg)
        notified_msg = msg
      end
      actions.close({})
      assert.equals("no remote", notified_msg)
    end)
  end)
end)
