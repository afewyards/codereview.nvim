local auth = require("glab_review.api.auth")
local config = require("glab_review.config")

describe("auth", function()
  before_each(function()
    config.reset()
    auth.reset()
  end)

  describe("get_token", function()
    it("reads from GITLAB_TOKEN env var first, returns pat type", function()
      vim.env.GITLAB_TOKEN = "test-env-token"
      local token, token_type = auth.get_token()
      assert.equals("test-env-token", token)
      assert.equals("pat", token_type)
      vim.env.GITLAB_TOKEN = nil
    end)

    it("reads from config.token second, returns pat type", function()
      config.setup({ token = "config-token" })
      local token, token_type = auth.get_token()
      assert.equals("config-token", token)
      assert.equals("pat", token_type)
    end)

    it("returns nil when no token available", function()
      config.setup({})
      local token, token_type = auth.get_token()
      assert.is_nil(token)
      assert.is_nil(token_type)
    end)

    it("caches token after first lookup", function()
      vim.env.GITLAB_TOKEN = "cached-token"
      auth.get_token()
      vim.env.GITLAB_TOKEN = nil
      local token, token_type = auth.get_token()
      assert.equals("cached-token", token)
      assert.equals("pat", token_type)
    end)

    it("reset clears cache", function()
      vim.env.GITLAB_TOKEN = "temp-token"
      auth.get_token()
      vim.env.GITLAB_TOKEN = nil
      auth.reset()
      local token = auth.get_token()
      assert.is_nil(token)
    end)
  end)
end)
