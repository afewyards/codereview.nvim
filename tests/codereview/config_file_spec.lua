local auth = require("codereview.api.auth")
local config = require("codereview.config")
local git = require("codereview.git")

local function make_tmpdir()
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  return tmpdir
end

local function write_config_file(dir, data)
  local path = dir .. "/.codereview.json"
  vim.fn.writefile({ vim.json.encode(data) }, path)
  return path
end

describe("config_file", function()
  local orig_get_repo_root
  local tmpdir

  before_each(function()
    config.reset()
    auth.reset()
    orig_get_repo_root = git.get_repo_root
    tmpdir = make_tmpdir()
    git.get_repo_root = function() return tmpdir end
  end)

  after_each(function()
    git.get_repo_root = orig_get_repo_root
    vim.fn.delete(tmpdir, "rf")
  end)

  it("reads platform-scoped github_token for github platform", function()
    write_config_file(tmpdir, { github_token = "ghp_file_token" })
    local token, token_type = auth.get_token("github")
    assert.equals("ghp_file_token", token)
    assert.equals("pat", token_type)
  end)

  it("reads platform-scoped gitlab_token for gitlab platform", function()
    write_config_file(tmpdir, { gitlab_token = "glpat_file_token" })
    local token, token_type = auth.get_token("gitlab")
    assert.equals("glpat_file_token", token)
    assert.equals("pat", token_type)
  end)

  it("falls back to generic token when no platform-scoped token", function()
    write_config_file(tmpdir, { token = "generic_file_token" })
    local token, token_type = auth.get_token("github")
    assert.equals("generic_file_token", token)
    assert.equals("pat", token_type)
  end)

  it("platform-scoped token takes precedence over generic token", function()
    write_config_file(tmpdir, { github_token = "ghp_specific", token = "generic" })
    local token = auth.get_token("github")
    assert.equals("ghp_specific", token)
  end)

  it("env var takes precedence over config file token", function()
    write_config_file(tmpdir, { github_token = "ghp_file_token" })
    vim.env.GITHUB_TOKEN = "ghp_env_token"
    local token = auth.get_token("github")
    assert.equals("ghp_env_token", token)
    vim.env.GITHUB_TOKEN = nil
  end)

  it("config file token takes precedence over plugin config token", function()
    write_config_file(tmpdir, { github_token = "ghp_file_token" })
    config.setup({ token = "plugin_config_token" })
    local token = auth.get_token("github")
    assert.equals("ghp_file_token", token)
  end)

  it("returns nil gracefully when config file is missing", function()
    -- no file written
    config.setup({})
    local token = auth.get_token("github")
    assert.is_nil(token)
  end)

  it("does not crash on invalid JSON", function()
    vim.fn.writefile({ "not valid json {{{{" }, tmpdir .. "/.codereview.json")
    config.setup({})
    local token = auth.get_token("github")
    assert.is_nil(token)
  end)

  it("does not crash when git root is nil", function()
    git.get_repo_root = function() return nil end
    config.setup({})
    local token = auth.get_token("github")
    assert.is_nil(token)
  end)

  it("caches config file across multiple get_token calls", function()
    local call_count = 0
    local orig_readfile = vim.fn.readfile
    vim.fn.readfile = function(path)
      call_count = call_count + 1
      return orig_readfile(path)
    end
    write_config_file(tmpdir, { github_token = "ghp_cached", gitlab_token = "glpat_cached" })
    auth.get_token("github") -- reads file (count = 1)
    auth.get_token("gitlab") -- reuses cached file (count still 1)
    vim.fn.readfile = orig_readfile
    assert.equals(1, call_count)
  end)
end)
