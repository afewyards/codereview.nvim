local config = require("codereview.config")

describe("config", function()
  before_each(function()
    config.reset()
  end)

  it("returns defaults when setup called with no args", function()
    config.setup({})
    local c = config.get()
    assert.is_nil(c.gitlab_url)
    assert.is_nil(c.project)
    assert.is_nil(c.picker)
    assert.equals(8, c.diff.context)
    assert.is_true(c.ai.enabled)
    assert.equals("claude", c.ai.claude_cli.cmd)
  end)

  it("merges user config over defaults", function()
    config.setup({ diff = { context = 5 }, picker = "fzf" })
    local c = config.get()
    assert.equals(5, c.diff.context)
    assert.equals("fzf", c.picker)
    assert.is_true(c.ai.enabled)
  end)

  it("validates context range", function()
    config.setup({ diff = { context = 25 } })
    local c = config.get()
    assert.equals(20, c.diff.context)
  end)

  it("defaults diff.scroll_threshold to 50", function()
    config.setup({})
    local c = config.get()
    assert.equals(50, c.diff.scroll_threshold)
  end)

  it("has github_token and gitlab_token defaults as nil", function()
    config.setup({})
    local c = config.get()
    assert.is_nil(c.github_token)
    assert.is_nil(c.gitlab_token)
    assert.is_nil(c.token) -- removed
  end)

  it("accepts github_token in setup", function()
    config.setup({ github_token = "ghp_abc" })
    local c = config.get()
    assert.equals("ghp_abc", c.github_token)
  end)

  it("accepts gitlab_token in setup", function()
    config.setup({ gitlab_token = "glpat-xyz" })
    local c = config.get()
    assert.equals("glpat-xyz", c.gitlab_token)
  end)

  it("warns when legacy token field is passed", function()
    local warned = false
    local orig = vim.notify
    vim.notify = function(msg, level)
      if msg:find("deprecated") and level == vim.log.levels.WARN then
        warned = true
      end
    end
    config.setup({ token = "old-token" })
    vim.notify = orig
    assert.is_true(warned)
  end)

  it("defaults ai.review_level to info", function()
    config.setup({})
    local c = config.get()
    assert.equals("info", c.ai.review_level)
  end)

  it("accepts valid review_level values", function()
    for _, level in ipairs({ "info", "suggestion", "warning", "error" }) do
      config.reset()
      config.setup({ ai = { review_level = level } })
      assert.equals(level, config.get().ai.review_level)
    end
  end)

  it("rejects invalid review_level and defaults to info", function()
    config.setup({ ai = { review_level = "critical" } })
    assert.equals("info", config.get().ai.review_level)
  end)

  it("includes separator defaults", function()
    config.setup({})
    local c = config.get()
    assert.equals("╳", c.diff.separator_char)
    assert.equals(2, c.diff.separator_lines)
  end)

  it("defaults ai.max_file_size to 500", function()
    config.setup({})
    assert.equals(500, config.get().ai.max_file_size)
  end)

  it("clamps ai.max_file_size to minimum 0", function()
    config.setup({ ai = { max_file_size = -10 } })
    assert.equals(0, config.get().ai.max_file_size)
  end)

  it("defaults ai.provider to claude_cli", function()
    config.setup({})
    assert.equals("claude_cli", config.get().ai.provider)
  end)

  it("defaults ai.claude_cli sub-table", function()
    config.setup({})
    local c = config.get()
    assert.equals("claude", c.ai.claude_cli.cmd)
    assert.equals("code-review", c.ai.claude_cli.agent)
  end)

  it("accepts ai.provider override", function()
    config.setup({ ai = { provider = "openai" } })
    assert.equals("openai", config.get().ai.provider)
  end)

  it("backward compat: claude_cmd maps to claude_cli.cmd", function()
    config.setup({ ai = { claude_cmd = "/opt/claude" } })
    local c = config.get()
    assert.equals("/opt/claude", c.ai.claude_cli.cmd)
  end)

  it("backward compat: agent maps to claude_cli.agent", function()
    config.setup({ ai = { agent = "my-agent" } })
    local c = config.get()
    assert.equals("my-agent", c.ai.claude_cli.agent)
  end)

  it("rejects invalid provider name", function()
    config.setup({ ai = { provider = "nonexistent" } })
    assert.equals("claude_cli", config.get().ai.provider)
  end)
end)
