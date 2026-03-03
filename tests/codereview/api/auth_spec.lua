local auth = require("codereview.api.auth")
local config = require("codereview.config")

describe("auth", function()
  local saved_github_token, saved_gitlab_token
  local saved_filereadable
  before_each(function()
    saved_github_token = vim.env.GITHUB_TOKEN
    saved_gitlab_token = vim.env.GITLAB_TOKEN
    vim.env.GITHUB_TOKEN = nil
    vim.env.GITLAB_TOKEN = nil
    -- Prevent .codereview.nvim config file from leaking tokens into tests
    saved_filereadable = vim.fn.filereadable
    vim.fn.filereadable = function(path)
      if path and path:match("%.codereview%.nvim$") then
        return 0
      end
      return saved_filereadable(path)
    end
    config.reset()
    auth.reset()
  end)
  after_each(function()
    vim.env.GITHUB_TOKEN = saved_github_token
    vim.env.GITLAB_TOKEN = saved_gitlab_token
    vim.fn.filereadable = saved_filereadable
  end)

  describe("get_token", function()
    it("reads from GITLAB_TOKEN env var first, returns pat type", function()
      vim.env.GITLAB_TOKEN = "test-env-token"
      local token, token_type = auth.get_token()
      assert.equals("test-env-token", token)
      assert.equals("pat", token_type)
      vim.env.GITLAB_TOKEN = nil
    end)

    it("reads from config gitlab_token when no env var", function()
      config.setup({ gitlab_token = "config-token" })
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

    it("reads github_token from config for github platform", function()
      config.setup({ github_token = "ghp_config" })
      local token, token_type = auth.get_token("github")
      assert.equals("ghp_config", token)
      assert.equals("pat", token_type)
    end)

    it("reads gitlab_token from config for gitlab platform", function()
      config.setup({ gitlab_token = "glpat_config" })
      local token, token_type = auth.get_token("gitlab")
      assert.equals("glpat_config", token)
      assert.equals("pat", token_type)
    end)

    it("does not cross-contaminate tokens between platforms", function()
      config.setup({ github_token = "ghp_only", gitlab_token = "glpat_only" })
      assert.equals("ghp_only", auth.get_token("github"))
      assert.equals("glpat_only", auth.get_token("gitlab"))
    end)

    it("refresh clears only the specified platform cache", function()
      vim.env.GITHUB_TOKEN = "ghp_cached"
      vim.env.GITLAB_TOKEN = "glpat_cached"
      auth.get_token("github")
      auth.get_token("gitlab")
      vim.env.GITHUB_TOKEN = nil
      vim.env.GITLAB_TOKEN = nil
      auth.refresh("github")
      assert.is_nil(auth.get_token("github"))
      assert.equals("glpat_cached", auth.get_token("gitlab"))
    end)
  end)

  describe("get_token with platform", function()
    before_each(function()
      auth.reset()
    end)
    it("reads GITHUB_TOKEN for github", function()
      vim.env.GITHUB_TOKEN = "ghp_test"
      assert.equal("ghp_test", auth.get_token("github"))
      vim.env.GITHUB_TOKEN = nil
    end)
    it("reads GITLAB_TOKEN for gitlab", function()
      vim.env.GITLAB_TOKEN = "glpat_test"
      assert.equal("glpat_test", auth.get_token("gitlab"))
      vim.env.GITLAB_TOKEN = nil
    end)
    it("defaults to gitlab when no platform arg", function()
      vim.env.GITLAB_TOKEN = "glpat_test"
      assert.equal("glpat_test", auth.get_token())
      vim.env.GITLAB_TOKEN = nil
    end)
  end)
end)
