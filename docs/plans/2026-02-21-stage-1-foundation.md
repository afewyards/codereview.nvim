# Stage 1: Foundation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Scaffold the plugin, build the API client with auth, and verify we can make authenticated GitLab API calls.

**Error handling pattern:** All internal APIs return `nil, err_string` on failure. User-facing surfaces use `vim.notify()` with appropriate log level. This pattern is established in Task 4 (client) and all subsequent stages follow it.

**Architecture:** Pure Lua Neovim plugin. HTTP via plenary.curl. Auth cascade: env var -> glab CLI config -> OAuth2 device flow -> stored token. Project auto-detected from git remote.

**Loading/progress indicators:** Add `vim.notify` progress messages for long operations (API calls). Example: `vim.notify('Fetching MRs...', vim.log.levels.INFO)` before async API calls.

**Tech Stack:** Lua, Neovim API, plenary.nvim, plenary.curl

---

### Task 1: Project Scaffolding

**Files:**
- Create: `lua/glab_review/init.lua`
- Create: `plugin/glab_review.lua`
- Create: `tests/minimal_init.lua`

**Step 1: Create minimal_init.lua for test harness**

```lua
-- tests/minimal_init.lua
local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
if vim.fn.isdirectory(plenary_dir) == 0 then
  vim.fn.system({ "git", "clone", "https://github.com/nvim-lua/plenary.nvim", plenary_dir })
end
vim.opt.runtimepath:append(".")
vim.opt.runtimepath:append(plenary_dir)
vim.cmd("runtime plugin/plenary.vim")
```

**Step 2: Create plugin loader**

```lua
-- plugin/glab_review.lua
if vim.g.loaded_glab_review then
  return
end
vim.g.loaded_glab_review = true
```

**Step 3: Create init.lua with empty setup()**

```lua
-- lua/glab_review/init.lua
local M = {}

function M.setup(opts)
  require("glab_review.config").setup(opts)
end

return M
```

**Step 4: Commit**

```bash
git add lua/glab_review/init.lua plugin/glab_review.lua tests/minimal_init.lua
git commit -m "chore: scaffold plugin structure"
```

---

### Task 2: Config Module

**Files:**
- Create: `lua/glab_review/config.lua`
- Create: `tests/glab_review/config_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/config_spec.lua
local config = require("glab_review.config")

describe("config", function()
  before_each(function()
    config.reset()
  end)

  it("returns defaults when setup called with no args", function()
    config.setup({})
    local c = config.get()
    assert.is_nil(c.gitlab_url)
    assert.is_nil(c.project)
    assert.is_nil(c.token)
    assert.is_nil(c.picker)
    assert.equals(3, c.diff.context)
    assert.is_true(c.ai.enabled)
    assert.equals("claude", c.ai.claude_cmd)
  end)

  it("merges user config over defaults", function()
    config.setup({ diff = { context = 5 }, picker = "fzf" })
    local c = config.get()
    assert.equals(5, c.diff.context)
    assert.equals("fzf", c.picker)
    assert.is_true(c.ai.enabled) -- untouched default
  end)

  it("validates context range", function()
    config.setup({ diff = { context = 25 } })
    local c = config.get()
    assert.equals(20, c.diff.context) -- clamped to max
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/glab_review/config_spec.lua"`
Expected: FAIL — module not found

**Step 3: Implement config module**

```lua
-- lua/glab_review/config.lua
local M = {}

local defaults = {
  gitlab_url = nil,
  project = nil,
  token = nil,
  picker = nil,
  diff = {
    context = 3,
  },
  ai = {
    enabled = true,
    claude_cmd = "claude",
  },
}

local current = nil

local function deep_merge(base, override)
  local result = vim.deepcopy(base)
  for k, v in pairs(override) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

local function validate(c)
  c.diff.context = math.max(0, math.min(20, c.diff.context))
  return c
end

function M.setup(opts)
  current = validate(deep_merge(defaults, opts or {}))
end

function M.get()
  return current or vim.deepcopy(defaults)
end

function M.reset()
  current = nil
end

return M
```

**Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/glab_review/config_spec.lua"`
Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/config.lua tests/glab_review/config_spec.lua
git commit -m "feat: add config module with defaults and validation"
```

---

### Task 3: Project Detection

**Files:**
- Create: `lua/glab_review/git.lua`
- Create: `tests/glab_review/git_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/git_spec.lua
local git = require("glab_review.git")

describe("git.parse_remote", function()
  it("parses SSH remote", function()
    local host, project = git.parse_remote("git@gitlab.com:group/project.git")
    assert.equals("gitlab.com", host)
    assert.equals("group/project", project)
  end)

  it("parses HTTPS remote", function()
    local host, project = git.parse_remote("https://gitlab.com/group/project.git")
    assert.equals("gitlab.com", host)
    assert.equals("group/project", project)
  end)

  it("parses HTTPS without .git suffix", function()
    local host, project = git.parse_remote("https://gitlab.com/group/subgroup/project")
    assert.equals("gitlab.com", host)
    assert.equals("group/subgroup/project", project)
  end)

  it("parses SSH with port", function()
    local host, project = git.parse_remote("ssh://git@gitlab.example.com:2222/team/repo.git")
    assert.equals("gitlab.example.com", host)
    assert.equals("team/repo", project)
  end)

  it("returns nil for invalid remote", function()
    local host, project = git.parse_remote("not-a-url")
    assert.is_nil(host)
    assert.is_nil(project)
  end)
end)

describe("git.detect_project", function()
  it("uses config overrides when set", function()
    config.setup({ gitlab_url = "https://custom.gitlab.com", project = "my/project" })
    local url, proj = git.detect_project()
    assert.equals("https://custom.gitlab.com", url)
    assert.equals("my/project", proj)
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/glab_review/git_spec.lua"`
Expected: FAIL

**Step 3: Implement git module**

```lua
-- lua/glab_review/git.lua
local M = {}

function M.parse_remote(url)
  if not url or url == "" then
    return nil, nil
  end

  -- SSH: git@host:group/project.git
  local host, path = url:match("^git@([^:]+):(.+)$")
  if host and path then
    path = path:gsub("%.git$", "")
    return host, path
  end

  -- SSH with scheme: ssh://git@host:port/path.git
  host, path = url:match("^ssh://[^@]+@([^:/]+)[:%d]*/(.+)$")
  if host and path then
    path = path:gsub("%.git$", "")
    return host, path
  end

  -- HTTPS: https://host/group/project.git
  host, path = url:match("^https?://([^/]+)/(.+)$")
  if host and path then
    path = path:gsub("%.git$", "")
    return host, path
  end

  return nil, nil
end

function M.get_remote_url()
  local result = vim.fn.systemlist({ "git", "remote", "get-url", "origin" })
  if vim.v.shell_error ~= 0 or #result == 0 then
    return nil
  end
  return vim.trim(result[1])
end

function M.detect_project()
  local config = require("glab_review.config").get()
  if config.gitlab_url and config.project then
    return config.gitlab_url, config.project
  end

  local url = M.get_remote_url()
  if not url then
    return nil, nil
  end

  local host, project = M.parse_remote(url)
  if not host then
    return nil, nil
  end

  return "https://" .. host, project
end

return M
```

**Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/glab_review/git_spec.lua"`
Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/git.lua tests/glab_review/git_spec.lua
git commit -m "feat: add git remote parsing and project detection"
```

---

### Task 4: API Client

**Files:**
- Create: `lua/glab_review/api/client.lua`
- Create: `tests/glab_review/api/client_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/api/client_spec.lua
-- NOTE: Tests cover sync-safe helpers only (build_url, encode_project, build_headers,
-- parse_next_page). Async variants (async_get, async_post, etc.) require a running
-- event loop and are tested via integration tests in later stages.
local client = require("glab_review.api.client")

describe("api.client", function()
  describe("build_url", function()
    it("builds API URL from base and path", function()
      local url = client.build_url("https://gitlab.com", "/projects/123/merge_requests")
      assert.equals("https://gitlab.com/api/v4/projects/123/merge_requests", url)
    end)

    it("URL-encodes project path", function()
      local encoded = client.encode_project("group/subgroup/project")
      assert.equals("group%2Fsubgroup%2Fproject", encoded)
    end)
  end)

  describe("build_headers", function()
    it("uses PRIVATE-TOKEN for PAT", function()
      local headers = client.build_headers("glpat-abc123", "pat")
      assert.equals("glpat-abc123", headers["PRIVATE-TOKEN"])
      assert.is_nil(headers["Authorization"])
    end)

    it("uses Authorization Bearer for OAuth", function()
      local headers = client.build_headers("oauth-token-xyz", "oauth")
      assert.equals("Bearer oauth-token-xyz", headers["Authorization"])
      assert.is_nil(headers["PRIVATE-TOKEN"])
    end)

    it("defaults to PRIVATE-TOKEN when no token_type given", function()
      local headers = client.build_headers("glpat-abc123")
      assert.equals("glpat-abc123", headers["PRIVATE-TOKEN"])
    end)

    it("includes Content-Type", function()
      local headers = client.build_headers("glpat-abc123")
      assert.equals("application/json", headers["Content-Type"])
    end)
  end)

  describe("parse_pagination", function()
    it("extracts next page from headers", function()
      local headers = { ["x-next-page"] = "3" }
      assert.equals(3, client.parse_next_page(headers))
    end)

    it("returns nil when no next page", function()
      local headers = { ["x-next-page"] = "" }
      assert.is_nil(client.parse_next_page(headers))
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/glab_review/api/client_spec.lua"`
Expected: FAIL

**Step 3: Implement API client**

```lua
-- lua/glab_review/api/client.lua
local curl = require("plenary.curl")
local async = require("plenary.async")
local async_util = require("plenary.async.util")
local M = {}

function M.encode_project(project_path)
  return project_path:gsub("/", "%%2F")
end

function M.build_url(base_url, path)
  return base_url .. "/api/v4" .. path
end

--- Build request headers based on token type.
--- @param token string The auth token value
--- @param token_type string|nil "pat" (default) or "oauth"
function M.build_headers(token, token_type)
  if token_type == "oauth" then
    return {
      ["Authorization"] = "Bearer " .. token,
      ["Content-Type"] = "application/json",
    }
  else
    -- "pat" or nil — use PRIVATE-TOKEN
    return {
      ["PRIVATE-TOKEN"] = token,
      ["Content-Type"] = "application/json",
    }
  end
end

function M.parse_next_page(headers)
  local next_page = headers and headers["x-next-page"]
  if next_page and next_page ~= "" then
    return tonumber(next_page)
  end
  return nil
end

local function build_params(method, base_url, path, token, token_type, opts)
  local url = M.build_url(base_url, path)
  local params = {
    url = url,
    headers = M.build_headers(token, token_type),
    method = method,
  }

  if opts.body then
    params.body = vim.json.encode(opts.body)
  end

  if opts.query then
    local parts = {}
    for k, v in pairs(opts.query) do
      table.insert(parts, k .. "=" .. vim.uri_encode(tostring(v)))
    end
    if #parts > 0 then
      params.url = params.url .. "?" .. table.concat(parts, "&")
    end
  end

  return params
end

local function process_response(response)
  local body = nil
  if response.body and response.body ~= "" then
    local ok, decoded = pcall(vim.json.decode, response.body)
    if ok then
      body = decoded
    else
      body = response.body
    end
  end

  return {
    data = body,
    status = response.status,
    headers = response.headers,
    next_page = M.parse_next_page(response.headers),
  }
end

--- Sync request — ONLY use in tests or non-interactive contexts.
--- All plugin callers should use M.async_request() instead.
function M.request(method, base_url, path, opts)
  opts = opts or {}
  local auth = require("glab_review.api.auth")
  local token, token_type = auth.get_token()
  if not token then
    return nil, "No authentication token. Run :GlabReviewAuth"
  end

  local params = build_params(method, base_url, path, token, token_type, opts)

  local response = curl.request(params)
  if not response then
    return nil, "Request failed: no response"
  end

  -- Respect rate limiting
  if response.status == 429 then
    local retry_after = tonumber(response.headers and response.headers["retry-after"]) or 5
    vim.notify(string.format("Rate limited. Retrying in %ds...", retry_after), vim.log.levels.WARN)
    vim.wait(retry_after * 1000)
    response = curl.request(params)
  end

  if response.status == 401 then
    -- Try token refresh
    local new_token, new_type = auth.refresh()
    if new_token then
      params.headers = M.build_headers(new_token, new_type)
      response = curl.request(params)
    end
  end

  if response.status < 200 or response.status >= 300 then
    return nil, string.format("HTTP %d: %s", response.status, response.body or "")
  end

  return process_response(response)
end

--- Async request — use this for all plugin callers to avoid blocking the UI thread.
--- Must be called from within a plenary.async coroutine.
function M.async_request(method, base_url, path, opts)
  opts = opts or {}
  local auth = require("glab_review.api.auth")
  local token, token_type = auth.get_token()
  if not token then
    return nil, "No authentication token. Run :GlabReviewAuth"
  end

  local params = build_params(method, base_url, path, token, token_type, opts)

  local response = async_util.wrap(curl.request, 2)(params)
  if not response then
    return nil, "Request failed: no response"
  end

  -- Respect rate limiting
  if response.status == 429 then
    local retry_after = tonumber(response.headers and response.headers["retry-after"]) or 5
    vim.schedule(function()
      vim.notify(string.format("Rate limited. Retrying in %ds...", retry_after), vim.log.levels.WARN)
    end)
    async_util.sleep(retry_after * 1000)
    response = async_util.wrap(curl.request, 2)(params)
  end

  if response.status == 401 then
    local new_token, new_type = auth.refresh()
    if new_token then
      params.headers = M.build_headers(new_token, new_type)
      response = async_util.wrap(curl.request, 2)(params)
    end
  end

  if response.status < 200 or response.status >= 300 then
    return nil, string.format("HTTP %d: %s", response.status, response.body or "")
  end

  return process_response(response)
end

-- Sync variants — ONLY use in tests.
function M.get(base_url, path, opts)
  return M.request("get", base_url, path, opts)
end

function M.post(base_url, path, opts)
  return M.request("post", base_url, path, opts)
end

function M.put(base_url, path, opts)
  return M.request("put", base_url, path, opts)
end

function M.delete(base_url, path, opts)
  return M.request("delete", base_url, path, opts)
end

-- Async variants — use these in all plugin callers (Stage 2+).
function M.async_get(base_url, path, opts)
  return M.async_request("get", base_url, path, opts)
end

function M.async_post(base_url, path, opts)
  return M.async_request("post", base_url, path, opts)
end

function M.async_put(base_url, path, opts)
  return M.async_request("put", base_url, path, opts)
end

function M.async_delete(base_url, path, opts)
  return M.async_request("delete", base_url, path, opts)
end

--- Paginate all pages of a GET request. Uses async_get to avoid blocking the UI.
--- Must be called from within a plenary.async coroutine.
function M.paginate_all(base_url, path, opts)
  -- Deep-copy to avoid mutating the caller's opts table.
  opts = vim.deepcopy(opts or {})
  local all_data = {}
  local page = 1
  local per_page = opts.per_page or 100

  while true do
    opts.query = opts.query or {}
    opts.query.page = page
    opts.query.per_page = per_page

    local result, err = M.async_get(base_url, path, opts)
    if not result then
      return nil, err
    end

    if type(result.data) == "table" then
      for _, item in ipairs(result.data) do
        table.insert(all_data, item)
      end
    end

    if not result.next_page then
      break
    end
    page = result.next_page
  end

  return all_data
end

return M
```

**Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/glab_review/api/client_spec.lua"`
Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/api/client.lua tests/glab_review/api/client_spec.lua
git commit -m "feat: add API client with async variants, OAuth Bearer header, 429 handling, and safe pagination"
```

---

### Task 5: Auth — PAT and glab CLI Piggyback

**Files:**
- Create: `lua/glab_review/api/auth.lua`
- Create: `tests/glab_review/api/auth_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/api/auth_spec.lua
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
  end)

  describe("parse_glab_config", function()
    it("extracts token for host from yaml", function()
      local yaml = [[
hosts:
    gitlab.com:
        token: glpat-from-glab
        api_protocol: https
]]
      local token = auth.parse_glab_config(yaml, "gitlab.com")
      assert.equals("glpat-from-glab", token)
    end)

    it("skips OAuth tokens", function()
      local yaml = [[
hosts:
    gitlab.com:
        token: oauth-short-lived
        is_oauth2: "true"
]]
      local token = auth.parse_glab_config(yaml, "gitlab.com")
      assert.is_nil(token)
    end)

    it("returns nil for unknown host", function()
      local yaml = [[
hosts:
    gitlab.com:
        token: glpat-abc
]]
      local token = auth.parse_glab_config(yaml, "other.host.com")
      assert.is_nil(token)
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/glab_review/api/auth_spec.lua"`
Expected: FAIL

**Step 3: Implement auth module**

```lua
-- lua/glab_review/api/auth.lua
local M = {}

local cached_token = nil
local cached_token_type = nil  -- "pat" or "oauth"

function M.reset()
  cached_token = nil
  cached_token_type = nil
end

--- Minimal YAML parser for glab config (handles the flat hosts structure only)
function M.parse_glab_config(yaml_str, target_host)
  local current_host = nil
  local token = nil
  local is_oauth = false

  for line in yaml_str:gmatch("[^\n]+") do
    -- Match host entry (indented under hosts:)
    local host = line:match("^%s%s%s%s(%S+):$")
    if host then
      -- Check previous host result
      if current_host == target_host and token and not is_oauth then
        return token
      end
      current_host = host
      token = nil
      is_oauth = false
    end

    if current_host then
      local t = line:match("^%s+token:%s+(.+)$")
      if t then
        token = vim.trim(t)
      end
      local oauth = line:match('is_oauth2:%s+"true"')
      if oauth then
        is_oauth = true
      end
    end
  end

  -- Check last host
  if current_host == target_host and token and not is_oauth then
    return token
  end

  return nil
end

function M.read_glab_config(host)
  local config_dir = os.getenv("GLAB_CONFIG_DIR")
    or os.getenv("XDG_CONFIG_HOME")
    or (os.getenv("HOME") .. "/.config")
  local path = config_dir .. "/glab-cli/config.yml"

  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()

  return M.parse_glab_config(content, host)
end

function M.read_stored_token()
  local data_dir = os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") .. "/.local/share")
  local path = data_dir .. "/glab-review/tokens.json"

  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()

  local ok, data = pcall(vim.json.decode, content)
  if not ok or not data then
    return nil
  end

  local git = require("glab_review.git")
  local base_url = git.detect_project()
  if not base_url then
    return nil
  end

  local host = base_url:match("https?://(.+)")
  local entry = data[host]
  if not entry or not entry.access_token then
    return nil
  end

  return entry.access_token
end

function M.store_token(host, token_data)
  local data_dir = os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") .. "/.local/share")
  local dir = data_dir .. "/glab-review"
  vim.fn.mkdir(dir, "p")

  local path = dir .. "/tokens.json"
  local existing = {}

  local f = io.open(path, "r")
  if f then
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    if ok and data then
      existing = data
    end
    f:close()
  end

  existing[host] = token_data

  f = io.open(path, "w")
  if f then
    f:write(vim.json.encode(existing))
    f:close()
    vim.fn.system({ "chmod", "600", path })
  end
end

--- Returns token, token_type. token_type is "pat" or "oauth".
--- All callers should unpack both values and pass token_type to build_headers().
function M.get_token()
  if cached_token then
    return cached_token, cached_token_type
  end

  -- 1. GITLAB_TOKEN env var
  local env_token = os.getenv("GITLAB_TOKEN")
  if env_token and env_token ~= "" then
    cached_token = env_token
    cached_token_type = "pat"
    return cached_token, cached_token_type
  end

  -- 2. Config token
  local config = require("glab_review.config").get()
  if config.token then
    cached_token = config.token
    cached_token_type = "pat"
    return cached_token, cached_token_type
  end

  -- 3. glab CLI config
  local git = require("glab_review.git")
  local base_url = git.detect_project()
  if base_url then
    local host = base_url:match("https?://(.+)")
    if host then
      local glab_token = M.read_glab_config(host)
      if glab_token then
        cached_token = glab_token
        cached_token_type = "pat"
        return cached_token, cached_token_type
      end
    end
  end

  -- 4. Stored OAuth token
  local stored = M.read_stored_token()
  if stored then
    cached_token = stored
    cached_token_type = "oauth"
    return cached_token, cached_token_type
  end

  return nil, nil
end

function M.refresh()
  -- Token refresh for OAuth - implemented in Task 6
  cached_token = nil
  cached_token_type = nil
  return nil, nil
end

return M
```

**Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/glab_review/api/auth_spec.lua"`
Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/api/auth.lua tests/glab_review/api/auth_spec.lua
git commit -m "feat: add auth module with PAT env var and glab CLI piggyback"
```

---

### Task 6: Auth — OAuth2 Device Flow

**Files:**
- Modify: `lua/glab_review/api/auth.lua`
- Create: `lua/glab_review/ui/float.lua` (minimal — needed for auth UI)
- Create: `tests/glab_review/api/auth_oauth_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/api/auth_oauth_spec.lua
local auth = require("glab_review.api.auth")

describe("auth.oauth", function()
  describe("build_device_code_request", function()
    it("builds correct request params", function()
      local params = auth.build_device_code_params("https://gitlab.com", "test-client-id")
      assert.equals("https://gitlab.com/oauth/authorize_device", params.url)
      assert.equals("client_id=test-client-id&scope=api", params.body)
    end)
  end)

  describe("build_token_poll_request", function()
    it("builds correct poll params", function()
      local params = auth.build_token_poll_params("https://gitlab.com", "test-client-id", "device-code-123")
      assert.equals("https://gitlab.com/oauth/token", params.url)
      assert.truthy(params.body:find("device_code=device-code-123"))
      assert.truthy(params.body:find("grant_type=urn"))
    end)
  end)

  describe("parse_device_code_response", function()
    it("extracts device code fields", function()
      local body = vim.json.encode({
        device_code = "abc",
        user_code = "XXXX-YYYY",
        verification_uri = "https://gitlab.com/oauth/device",
        verification_uri_complete = "https://gitlab.com/oauth/device?user_code=XXXX-YYYY",
        expires_in = 300,
        interval = 5,
      })
      local data = auth.parse_device_code_response(body)
      assert.equals("abc", data.device_code)
      assert.equals("XXXX-YYYY", data.user_code)
      assert.equals(5, data.interval)
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Add OAuth methods to auth.lua**

Add these functions to the existing `lua/glab_review/api/auth.lua`:

```lua
-- OAuth2 Device Flow helpers

M.CLIENT_ID = "glab-review-nvim" -- Replace with registered app client_id

function M.build_device_code_params(base_url, client_id)
  return {
    url = base_url .. "/oauth/authorize_device",
    body = "client_id=" .. (client_id or M.CLIENT_ID) .. "&scope=api",
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
  }
end

function M.build_token_poll_params(base_url, client_id, device_code)
  return {
    url = base_url .. "/oauth/token",
    body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
      .. "&device_code=" .. device_code
      .. "&client_id=" .. (client_id or M.CLIENT_ID),
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
  }
end

function M.parse_device_code_response(body)
  local ok, data = pcall(vim.json.decode, body)
  if not ok then
    return nil
  end
  return data
end

function M.start_device_flow(base_url, callback)
  local curl = require("plenary.curl")
  local params = M.build_device_code_params(base_url)

  curl.post(params.url, {
    body = params.body,
    headers = params.headers,
    callback = function(response)
      if response.status ~= 200 then
        vim.schedule(function()
          callback(nil, "Device auth request failed: HTTP " .. response.status)
        end)
        return
      end

      local data = M.parse_device_code_response(response.body)
      if not data then
        vim.schedule(function()
          callback(nil, "Failed to parse device code response")
        end)
        return
      end

      vim.schedule(function()
        -- Show user code in floating window
        local float = require("glab_review.ui.float")
        local lines = {
          "GitLab Device Authorization",
          "",
          "Open this URL in your browser:",
          data.verification_uri_complete or data.verification_uri,
          "",
          "Enter code: " .. data.user_code,
          "",
          "Waiting for authorization...",
        }
        local win_id = float.open(lines, { title = "GlabReview Auth", width = 60 })

        -- Poll for token
        local timer = vim.loop.new_timer()
        local interval = (data.interval or 5) * 1000
        local attempts = 0
        local max_attempts = math.floor((data.expires_in or 300) / (data.interval or 5))

        timer:start(interval, interval, function()
          attempts = attempts + 1
          if attempts > max_attempts then
            timer:stop()
            timer:close()
            vim.schedule(function()
              float.close(win_id)
              callback(nil, "Authorization timed out")
            end)
            return
          end

          local poll_params = M.build_token_poll_params(base_url, nil, data.device_code)
          local resp = curl.post(poll_params.url, {
            body = poll_params.body,
            headers = poll_params.headers,
          })

          if resp and resp.status == 200 then
            timer:stop()
            timer:close()
            local token_data = vim.json.decode(resp.body)
            local host = base_url:match("https?://(.+)")
            M.store_token(host, token_data)
            cached_token = token_data.access_token
            cached_token_type = "oauth"
            vim.schedule(function()
              float.close(win_id)
              callback(token_data.access_token)
            end)
          end
          -- On error responses (authorization_pending), keep polling
        end)
      end)
    end,
  })
end

function M.refresh()
  cached_token = nil
  cached_token_type = nil
  local git = require("glab_review.git")
  local base_url = git.detect_project()
  if not base_url then
    return nil, nil
  end

  local host = base_url:match("https?://(.+)")
  local data_dir = os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") .. "/.local/share")
  local path = data_dir .. "/glab-review/tokens.json"

  local f = io.open(path, "r")
  if not f then return nil, nil end
  local ok, stored = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if not ok or not stored or not stored[host] or not stored[host].refresh_token then
    return nil, nil
  end

  local curl = require("plenary.curl")
  local resp = curl.post(base_url .. "/oauth/token", {
    body = "grant_type=refresh_token"
      .. "&client_id=" .. M.CLIENT_ID
      .. "&refresh_token=" .. stored[host].refresh_token,
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
  })

  if resp and resp.status == 200 then
    local token_data = vim.json.decode(resp.body)
    M.store_token(host, token_data)
    cached_token = token_data.access_token
    cached_token_type = "oauth"
    return cached_token, cached_token_type
  end

  return nil, nil
end
```

**Step 4: Create minimal float helper**

```lua
-- lua/glab_review/ui/float.lua
local M = {}

function M.open(lines, opts)
  opts = opts or {}
  local width = opts.width or 60
  local height = opts.height or #lines
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "center" or nil,
  })

  vim.keymap.set("n", "q", function()
    M.close(win)
  end, { buffer = buf })

  return win
end

function M.close(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

return M
```

**Step 5: Run test to verify it passes**

Expected: PASS

**Step 6: Commit**

```bash
git add lua/glab_review/api/auth.lua lua/glab_review/ui/float.lua tests/glab_review/api/auth_oauth_spec.lua
git commit -m "feat: add OAuth2 device flow and floating window helper"
```

---

### Task 7: API Endpoints Module

**Files:**
- Create: `lua/glab_review/api/endpoints.lua`
- Create: `tests/glab_review/api/endpoints_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/api/endpoints_spec.lua
local endpoints = require("glab_review.api.endpoints")

describe("endpoints", function()
  it("builds MR list path", function()
    local path = endpoints.mr_list("group%2Fproject")
    assert.equals("/projects/group%2Fproject/merge_requests", path)
  end)

  it("builds MR detail path", function()
    local path = endpoints.mr_detail("group%2Fproject", 42)
    assert.equals("/projects/group%2Fproject/merge_requests/42", path)
  end)

  it("builds MR diffs path", function()
    local path = endpoints.mr_diffs("group%2Fproject", 42)
    assert.equals("/projects/group%2Fproject/merge_requests/42/diffs", path)
  end)

  it("builds discussions path", function()
    local path = endpoints.discussions("group%2Fproject", 42)
    assert.equals("/projects/group%2Fproject/merge_requests/42/discussions", path)
  end)

  it("builds draft notes path", function()
    local path = endpoints.draft_notes("group%2Fproject", 42)
    assert.equals("/projects/group%2Fproject/merge_requests/42/draft_notes", path)
  end)

  it("builds pipeline jobs path", function()
    local path = endpoints.pipeline_jobs("group%2Fproject", 999)
    assert.equals("/projects/group%2Fproject/pipelines/999/jobs", path)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement endpoints**

```lua
-- lua/glab_review/api/endpoints.lua
local M = {}

local function project_path(project_id)
  return "/projects/" .. project_id
end

local function mr_path(project_id, iid)
  return project_path(project_id) .. "/merge_requests/" .. iid
end

-- MR
function M.mr_list(project_id)
  return project_path(project_id) .. "/merge_requests"
end

function M.mr_detail(project_id, iid)
  return mr_path(project_id, iid)
end

function M.mr_diffs(project_id, iid)
  return mr_path(project_id, iid) .. "/diffs"
end

function M.mr_approve(project_id, iid)
  return mr_path(project_id, iid) .. "/approve"
end

function M.mr_unapprove(project_id, iid)
  return mr_path(project_id, iid) .. "/unapprove"
end

function M.mr_merge(project_id, iid)
  return mr_path(project_id, iid) .. "/merge"
end

-- Discussions
function M.discussions(project_id, iid)
  return mr_path(project_id, iid) .. "/discussions"
end

function M.discussion_notes(project_id, iid, discussion_id)
  return mr_path(project_id, iid) .. "/discussions/" .. discussion_id .. "/notes"
end

function M.discussion(project_id, iid, discussion_id)
  return mr_path(project_id, iid) .. "/discussions/" .. discussion_id
end

-- Draft Notes
function M.draft_notes(project_id, iid)
  return mr_path(project_id, iid) .. "/draft_notes"
end

function M.draft_note(project_id, iid, draft_note_id)
  return mr_path(project_id, iid) .. "/draft_notes/" .. draft_note_id
end

function M.draft_notes_publish(project_id, iid)
  return mr_path(project_id, iid) .. "/draft_notes/bulk_publish"
end

-- Pipeline
function M.mr_pipelines(project_id, iid)
  return mr_path(project_id, iid) .. "/pipelines"
end

function M.pipeline(project_id, pipeline_id)
  return project_path(project_id) .. "/pipelines/" .. pipeline_id
end

function M.pipeline_jobs(project_id, pipeline_id)
  return project_path(project_id) .. "/pipelines/" .. pipeline_id .. "/jobs"
end

function M.job_trace(project_id, job_id)
  return project_path(project_id) .. "/jobs/" .. job_id .. "/trace"
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/api/endpoints.lua tests/glab_review/api/endpoints_spec.lua
git commit -m "feat: add GitLab API endpoint path builders"
```

---

### Task 8: Command Registration + :GlabReviewAuth

**Files:**
- Modify: `plugin/glab_review.lua`
- Modify: `lua/glab_review/init.lua`

**Step 1: Add commands to plugin loader**

```lua
-- plugin/glab_review.lua
if vim.g.loaded_glab_review then
  return
end
vim.g.loaded_glab_review = true

vim.api.nvim_create_user_command("GlabReviewAuth", function()
  require("glab_review").auth()
end, { desc = "Authenticate with GitLab" })

vim.api.nvim_create_user_command("GlabReview", function()
  require("glab_review").open()
end, { desc = "Open MR picker" })

vim.api.nvim_create_user_command("GlabReviewPipeline", function()
  require("glab_review").pipeline()
end, { desc = "Show pipeline for current MR" })

vim.api.nvim_create_user_command("GlabReviewAI", function()
  require("glab_review").ai_review()
end, { desc = "Run AI review on current MR" })

vim.api.nvim_create_user_command("GlabReviewSubmit", function()
  require("glab_review").submit()
end, { desc = "Submit draft comments" })

vim.api.nvim_create_user_command("GlabReviewApprove", function()
  require("glab_review").approve()
end, { desc = "Approve current MR" })

vim.api.nvim_create_user_command("GlabReviewOpen", function()
  require("glab_review").create_mr()
end, { desc = "Create new MR" })
```

**Step 2: Add auth entry point to init.lua**

```lua
-- lua/glab_review/init.lua
local M = {}

function M.setup(opts)
  require("glab_review.config").setup(opts)
end

function M.auth()
  local git = require("glab_review.git")
  local auth = require("glab_review.api.auth")

  local token = auth.get_token()
  if token then
    vim.notify("Already authenticated", vim.log.levels.INFO)
    return
  end

  local base_url = git.detect_project()
  if not base_url then
    vim.notify("Could not detect GitLab instance. Set gitlab_url in setup().", vim.log.levels.ERROR)
    return
  end

  auth.start_device_flow(base_url, function(access_token, err)
    if err then
      vim.notify("Auth failed: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("Authenticated successfully!", vim.log.levels.INFO)
  end)
end

-- Stubs for later stages
function M.open() vim.notify("MR picker not yet implemented (Stage 2)", vim.log.levels.WARN) end
function M.pipeline() vim.notify("Pipeline not yet implemented (Stage 4)", vim.log.levels.WARN) end
function M.ai_review() vim.notify("AI review not yet implemented (Stage 5)", vim.log.levels.WARN) end
function M.submit() vim.notify("Submit not yet implemented (Stage 5)", vim.log.levels.WARN) end
function M.approve() vim.notify("Approve not yet implemented (Stage 3)", vim.log.levels.WARN) end
function M.create_mr() vim.notify("Create MR not yet implemented (Stage 5)", vim.log.levels.WARN) end

return M
```

**Step 3: Manually test**

Open Neovim in a git repo with a GitLab remote:
1. `:GlabReviewAuth` — should start device flow or report already authenticated
2. `:GlabReview` — should show "not yet implemented" message

**Note:** Add a test that verifies commands are registered after plugin load (check `vim.api.nvim_get_commands({})`).

**Step 4: Commit**

```bash
git add plugin/glab_review.lua lua/glab_review/init.lua
git commit -m "feat: register commands and wire up :GlabReviewAuth"
```

---

### Stage 1 Deliverable Checklist

- [ ] `require("glab_review").setup({})` works
- [ ] Config merging and validation works
- [ ] Git remote parsing extracts host + project for SSH/HTTPS
- [ ] API client builds correct URLs, headers, handles pagination
- [ ] Auth cascade: env var -> config -> glab CLI -> stored token
- [ ] OAuth device flow shows floating window, polls, stores token
- [ ] All endpoint path builders tested
- [ ] `:GlabReviewAuth` command works end-to-end
- [ ] Async API variants available (`async_get`, `async_post`, etc.)
- [ ] OAuth Bearer token header used for OAuth tokens
- [ ] 429 rate-limit handling with Retry-After
- [ ] `paginate_all` does not mutate caller's opts
