local auth = require("codereview.api.auth")
local config = require("codereview.config")
local git = require("codereview.git")

local function make_tmpdir()
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")
  return tmpdir
end

--- Write a .codereview.nvim dotenv-style config file.
--- @param dir string directory path
--- @param lines string[] lines to write (raw, no processing)
local function write_config_file(dir, lines)
  local path = dir .. "/.codereview.nvim"
  vim.fn.writefile(lines, path)
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
    git.get_repo_root = function()
      return tmpdir
    end
  end)

  after_each(function()
    git.get_repo_root = orig_get_repo_root
    vim.fn.delete(tmpdir, "rf")
  end)

  -- Token resolution via get_token() ---

  it("reads token from .codereview.nvim file", function()
    write_config_file(tmpdir, { "token = ghp_file_token" })
    local token, token_type = auth.get_token("github")
    assert.equals("ghp_file_token", token)
    assert.equals("pat", token_type)
  end)

  it("env var takes precedence over config file token", function()
    write_config_file(tmpdir, { "token = file_token" })
    vim.env.GITHUB_TOKEN = "ghp_env_token"
    local token = auth.get_token("github")
    assert.equals("ghp_env_token", token)
    vim.env.GITHUB_TOKEN = nil
  end)

  it("config file token takes precedence over plugin config token", function()
    write_config_file(tmpdir, { "token = ghp_file_token" })
    config.setup({ github_token = "plugin_config_token" })
    local token = auth.get_token("github")
    assert.equals("ghp_file_token", token)
  end)

  it("returns nil gracefully when config file is missing", function()
    -- no file written
    config.setup({})
    local token = auth.get_token("github")
    assert.is_nil(token)
  end)

  it("does not crash when git root is nil", function()
    git.get_repo_root = function()
      return nil
    end
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
    write_config_file(tmpdir, { "token = ghp_cached" })
    auth.get_token("github") -- reads file (count = 1)
    auth.get_token("gitlab") -- reuses cached file (count still 1)
    vim.fn.readfile = orig_readfile
    assert.equals(1, call_count)
  end)

  -- Dotenv parser behaviour (via _read_config_file_for_test) ---

  it("skips comment lines starting with #", function()
    write_config_file(tmpdir, {
      "# this is a comment",
      "token = real_token",
      "# another comment",
    })
    local parsed = auth._read_config_file_for_test()
    assert.equals("real_token", parsed.token)
    assert.is_nil(parsed["# this is a comment"])
  end)

  it("skips blank lines", function()
    write_config_file(tmpdir, {
      "",
      "token = blank_test",
      "",
    })
    local parsed = auth._read_config_file_for_test()
    assert.equals("blank_test", parsed.token)
  end)

  it("trims whitespace from keys and values", function()
    write_config_file(tmpdir, { "  token  =  padded_value  " })
    local parsed = auth._read_config_file_for_test()
    assert.equals("padded_value", parsed.token)
  end)

  it("handles values containing =", function()
    write_config_file(tmpdir, { "token = abc=def=ghi" })
    local parsed = auth._read_config_file_for_test()
    assert.equals("abc=def=ghi", parsed.token)
  end)

  it("reads platform and project keys", function()
    write_config_file(tmpdir, {
      "platform = github",
      "project = owner/repo",
    })
    local parsed = auth._read_config_file_for_test()
    assert.equals("github", parsed.platform)
    assert.equals("owner/repo", parsed.project)
  end)
end)

-- providers.detect() respects .codereview.nvim overrides (issue #25) ---

describe("providers.detect with config file overrides", function()
  local orig_get_repo_root
  local orig_get_remote_url
  local orig_parse_remote
  local tmpdir

  before_each(function()
    config.reset()
    auth.reset()
    orig_get_repo_root = git.get_repo_root
    orig_get_remote_url = git.get_remote_url
    orig_parse_remote = git.parse_remote
    tmpdir = make_tmpdir()
    git.get_repo_root = function()
      return tmpdir
    end
  end)

  after_each(function()
    git.get_repo_root = orig_get_repo_root
    git.get_remote_url = orig_get_remote_url
    git.parse_remote = orig_parse_remote
    vim.fn.delete(tmpdir, "rf")
  end)

  it("uses platform/project/base_url from config file (reproduces issue #25)", function()
    write_config_file(tmpdir, {
      "platform = gitlab",
      "project = 26",
      "base_url = https://gitlab.self-hosted.com",
    })
    local providers = require("codereview.providers")
    local _, ctx, err = providers.detect()
    assert.is_nil(err)
    assert.equals("26", ctx.project)
    assert.equals("https://gitlab.self-hosted.com", ctx.base_url)
    assert.equals("gitlab", ctx.platform)
    assert.equals("gitlab.self-hosted.com", ctx.host)
  end)

  it("config file project/base_url take precedence over plugin config values", function()
    config.setup({
      project = "plugin-project",
      base_url = "https://gitlab.plugin-configured.com",
    })
    write_config_file(tmpdir, {
      "project = file-project",
      "base_url = https://gitlab.file-configured.com",
    })
    local providers = require("codereview.providers")
    local _, ctx, err = providers.detect()
    assert.is_nil(err)
    assert.equals("file-project", ctx.project)
    assert.equals("https://gitlab.file-configured.com", ctx.base_url)
  end)

  it("falls back to git remote parsing when no config file is present", function()
    -- no file written; mock git remote so detect() succeeds without a real remote
    git.get_remote_url = function()
      return "git@github.com:owner/myrepo.git"
    end
    git.parse_remote = function(_url)
      return "github.com", "owner/myrepo"
    end
    local providers = require("codereview.providers")
    local _, ctx, err = providers.detect()
    assert.is_nil(err)
    assert.equals("owner/myrepo", ctx.project)
    assert.equals("github.com", ctx.host)
    assert.equals("github", ctx.platform)
  end)
end)
