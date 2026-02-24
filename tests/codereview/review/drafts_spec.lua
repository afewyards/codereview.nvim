-- Stub providers module
local _mock_provider
local _mock_client = {}
local _mock_ctx = { base_url = "https://example.com", project = "owner/repo" }

package.loaded["codereview.providers"] = {
  detect = function() return _mock_provider, _mock_ctx, nil end,
}
package.loaded["codereview.api.client"] = _mock_client
package.loaded["codereview.review.session"] = {
  start = function() end,
  get = function() return { active = false } end,
}

-- Ensure vim.ui exists for check_and_prompt tests
vim.ui = vim.ui or { select = function() end }

local drafts = require("codereview.review.drafts")

describe("review.drafts", function()
  describe("fetch_server_drafts", function()
    it("calls get_draft_notes for gitlab provider", function()
      local called = false
      _mock_provider = {
        name = "gitlab",
        get_draft_notes = function()
          called = true
          return {}
        end,
      }
      local result = drafts.fetch_server_drafts(_mock_provider, _mock_client, _mock_ctx, { id = 1 })
      assert.is_true(called)
      assert.equal(0, #result)
    end)

    it("calls get_pending_review_drafts for github provider", function()
      local called = false
      _mock_provider = {
        name = "github",
        get_pending_review_drafts = function()
          called = true
          return {}
        end,
      }
      local result = drafts.fetch_server_drafts(_mock_provider, _mock_client, _mock_ctx, { id = 1 })
      assert.is_true(called)
      assert.equal(0, #result)
    end)

    it("returns drafts when provider has them", function()
      _mock_provider = {
        name = "gitlab",
        get_draft_notes = function()
          return {
            { notes = {{ author = "You (draft)", body = "fix", position = { new_path = "a.lua", new_line = 1 } }}, is_draft = true, server_draft_id = 1 },
          }
        end,
      }
      local result = drafts.fetch_server_drafts(_mock_provider, _mock_client, _mock_ctx, { id = 1 })
      assert.equal(1, #result)
    end)

    it("returns empty table on provider error", function()
      _mock_provider = {
        name = "gitlab",
        get_draft_notes = function() return nil, "auth error" end,
      }
      local result = drafts.fetch_server_drafts(_mock_provider, _mock_client, _mock_ctx, { id = 1 })
      assert.equal(0, #result)
    end)
  end)

  describe("discard_server_drafts", function()
    it("deletes each draft note for gitlab", function()
      local deleted_ids = {}
      _mock_provider = {
        name = "gitlab",
        delete_draft_note = function(_, _, review, id)
          table.insert(deleted_ids, id)
        end,
      }
      local server_drafts = {
        { server_draft_id = 10 },
        { server_draft_id = 20 },
      }
      drafts.discard_server_drafts(_mock_provider, _mock_client, _mock_ctx, { id = 1 }, server_drafts)
      assert.equal(2, #deleted_ids)
      assert.equal(10, deleted_ids[1])
      assert.equal(20, deleted_ids[2])
    end)

    it("calls discard_pending_review for github", function()
      local called = false
      _mock_provider = {
        name = "github",
        discard_pending_review = function()
          called = true
        end,
      }
      drafts.discard_server_drafts(_mock_provider, _mock_client, _mock_ctx, { id = 1 }, {})
      assert.is_true(called)
    end)
  end)

  describe("check_and_prompt", function()
    it("calls on_done(nil) when no drafts exist", function()
      _mock_provider = {
        name = "gitlab",
        get_draft_notes = function() return {} end,
      }
      local result_arg = "not_called"
      drafts.check_and_prompt(_mock_provider, _mock_client, _mock_ctx, { id = 1 }, function(d)
        result_arg = d
      end)
      assert.is_nil(result_arg)
    end)

    it("calls on_done with drafts when user selects Resume", function()
      local server_drafts = {
        { notes = {{ author = "You (draft)", body = "fix" }}, is_draft = true, server_draft_id = 1 },
      }
      _mock_provider = {
        name = "gitlab",
        get_draft_notes = function() return server_drafts end,
      }
      -- Stub vim.ui.select to auto-choose "Resume"
      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice) on_choice("Resume") end

      local result_arg
      drafts.check_and_prompt(_mock_provider, _mock_client, _mock_ctx, { id = 1 }, function(d)
        result_arg = d
      end)
      assert.equal(1, #result_arg)
      assert.is_true(result_arg[1].is_draft)

      vim.ui.select = orig_select
    end)

    it("discards and calls on_done(nil) when user selects Discard", function()
      local discarded = false
      _mock_provider = {
        name = "gitlab",
        get_draft_notes = function()
          return { { server_draft_id = 10, is_draft = true, notes = {{}} } }
        end,
        delete_draft_note = function() discarded = true end,
      }
      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice) on_choice("Discard") end

      local result_arg = "not_called"
      drafts.check_and_prompt(_mock_provider, _mock_client, _mock_ctx, { id = 1 }, function(d)
        result_arg = d
      end)
      assert.is_nil(result_arg)
      assert.is_true(discarded)

      vim.ui.select = orig_select
    end)

    it("calls on_done(nil) when user cancels prompt", function()
      _mock_provider = {
        name = "gitlab",
        get_draft_notes = function()
          return { { server_draft_id = 10, is_draft = true, notes = {{}} } }
        end,
      }
      local orig_select = vim.ui.select
      vim.ui.select = function(items, opts, on_choice) on_choice(nil) end

      local result_arg = "not_called"
      drafts.check_and_prompt(_mock_provider, _mock_client, _mock_ctx, { id = 1 }, function(d)
        result_arg = d
      end)
      assert.is_nil(result_arg)

      vim.ui.select = orig_select
    end)
  end)
end)
