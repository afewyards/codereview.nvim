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
      approve = spy.new(function() return { ok = true }, nil end),
      unapprove = spy.new(function() return { ok = true }, nil end),
      merge = spy.new(function() return { ok = true }, nil end),
      close = spy.new(function() return { ok = true }, nil end),
    }

    stub(providers, "detect").returns(mock_provider, mock_ctx, nil)

    -- stub require for client so provider receives our mock_client
    package.loaded["codereview.api.client"] = mock_client
  end)

  after_each(function()
    providers.detect:revert()
    package.loaded["codereview.api.client"] = nil
  end)

  describe("approve", function()
    it("calls provider.approve with client, ctx, and review", function()
      local review = { iid = 1, sha = "abc" }
      local result, err = actions.approve(review)
      assert.is_nil(err)
      assert.spy(mock_provider.approve).was_called_with(mock_client, mock_ctx, review)
    end)

    it("returns nil and error when detect fails", function()
      providers.detect:revert()
      stub(providers, "detect").returns(nil, nil, "no remote")
      local result, err = actions.approve({})
      assert.is_nil(result)
      assert.equals("no remote", err)
    end)
  end)

  describe("unapprove", function()
    it("calls provider.unapprove with client, ctx, and review", function()
      local review = { iid = 2 }
      actions.unapprove(review)
      assert.spy(mock_provider.unapprove).was_called_with(mock_client, mock_ctx, review)
    end)

    it("calls vim.notify with WARN when provider returns an error", function()
      mock_provider.unapprove = spy.new(function() return nil, "unapprove failed" end)
      local notified_msg, notified_level
      _G.vim = _G.vim or {}
      _G.vim.notify = function(msg, level) notified_msg = msg; notified_level = level end
      _G.vim.log = _G.vim.log or {}
      _G.vim.log.levels = _G.vim.log.levels or { WARN = 3 }

      local result, err = actions.unapprove({ iid = 2 })
      assert.is_nil(result)
      assert.equals("unapprove failed", err)
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

    it("returns nil and error when detect fails", function()
      providers.detect:revert()
      stub(providers, "detect").returns(nil, nil, "no remote")
      local result, err = actions.merge({}, {})
      assert.is_nil(result)
      assert.equals("no remote", err)
    end)
  end)

  describe("close", function()
    it("calls provider.close with client, ctx, and review", function()
      local review = { iid = 4 }
      actions.close(review)
      assert.spy(mock_provider.close).was_called_with(mock_client, mock_ctx, review)
    end)

    it("returns nil and error when detect fails", function()
      providers.detect:revert()
      stub(providers, "detect").returns(nil, nil, "no remote")
      local result, err = actions.close({})
      assert.is_nil(result)
      assert.equals("no remote", err)
    end)
  end)
end)
