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
    git.get_repo_root = function() return tmpdir end
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
