# Platform-Specific Token Configuration — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `token` with `github_token`/`gitlab_token` in setup so both platforms work in one session.

**Architecture:** Config defaults get two new keys. `auth.get_token()` reads the platform-specific key from config. Deprecation warning if legacy `token` passed.

**Tech Stack:** Lua, Busted (test runner)

---

### Task 1: Config — tests for new token fields

**Files:**
- Modify: `tests/codereview/config_spec.lua`

**Step 1: Write failing tests**

Add to end of existing `describe("config")` block:

```lua
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
```

**Step 2: Run tests to verify they fail**

Run: `bunx busted tests/codereview/config_spec.lua`
Expected: FAIL — `c.token` still exists in defaults, no `github_token`/`gitlab_token`, no deprecation warning.

**Step 3: Commit**

```
test(config): add tests for platform-specific token fields
```

---

### Task 2: Config — implement platform-specific token fields

**Files:**
- Modify: `lua/codereview/config.lua`

**Step 1: Update defaults — replace `token = nil` with two fields**

In `defaults` table (line 4-14), change:

```lua
-- REMOVE:
token = nil,

-- ADD:
github_token = nil,
gitlab_token = nil,
```

**Step 2: Add deprecation warning in `M.setup`**

After the `gitlab_url` backward-compat block (line 38-40), add:

```lua
if current.token then
  vim.notify(
    "[codereview] `token` is deprecated. Use `github_token` or `gitlab_token` instead.",
    vim.log.levels.WARN
  )
end
```

**Step 3: Run tests**

Run: `bunx busted tests/codereview/config_spec.lua`
Expected: All pass.

**Step 4: Commit**

```
feat(config): replace token with github_token and gitlab_token
```

---

### Task 3: Auth — tests for platform-specific config lookup

**Files:**
- Modify: `tests/codereview/api/auth_spec.lua`

**Step 1: Write failing tests**

Update existing `"reads from config.token second"` test and add new ones. Replace/add inside `describe("get_token")`:

```lua
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
```

Also update/remove the old `"reads from config.token second"` test since `token` is deprecated.

**Step 2: Run tests to verify failures**

Run: `bunx busted tests/codereview/api/auth_spec.lua`
Expected: FAIL — `auth.get_token` still reads `config.token`, not platform-specific fields.

**Step 3: Commit**

```
test(auth): add tests for platform-specific token config lookup
```

---

### Task 4: Auth — implement platform-specific config lookup

**Files:**
- Modify: `lua/codereview/api/auth.lua`

**Step 1: Update step 3 (plugin config) in `get_token`**

Replace lines 95-101:

```lua
-- 3. Plugin config (platform-specific)
local config = require("codereview.config").get()
local config_key = platform == "github" and "github_token" or "gitlab_token"
if config[config_key] then
  log.info("get_token: using plugin config " .. config_key)
  cached[platform] = { token = config[config_key], type = "pat" }
  return config[config_key], "pat"
end
```

**Step 2: Run auth tests**

Run: `bunx busted tests/codereview/api/auth_spec.lua`
Expected: All pass.

**Step 3: Run config_file tests too (regression)**

Run: `bunx busted tests/codereview/config_file_spec.lua`
Expected: All pass (dotenv `token` field still works as step 2).

**Step 4: Commit**

```
feat(auth): read platform-specific token from config
```

---

### Task 5: Fix existing tests that reference old `token` field

**Files:**
- Modify: `tests/codereview/api/auth_spec.lua`
- Modify: `tests/codereview/config_spec.lua`
- Modify: `tests/codereview/config_file_spec.lua`

**Step 1: Update auth_spec.lua**

The test `"reads from config.token second"` (line 19-24) uses `config.setup({ token = "config-token" })`. This now triggers a deprecation warning and `config.token` still exists in the merged config (passed by user). The auth code no longer reads `config.token`. Update to use platform-specific field:

```lua
it("reads from config gitlab_token when no env var", function()
  config.setup({ gitlab_token = "config-token" })
  local token, token_type = auth.get_token()
  assert.equals("config-token", token)
  assert.equals("pat", token_type)
end)
```

**Step 2: Update config_spec.lua**

Line 13 asserts `assert.is_nil(c.token)` — this now passes since `token` was removed from defaults. Keep it as-is (it documents that `token` is gone).

**Step 3: Update config_file_spec.lua**

Line 54-59: test `"config file token takes precedence over plugin config token"` uses `config.setup({ token = "plugin_config_token" })`. Change to:

```lua
it("config file token takes precedence over plugin config token", function()
  write_config_file(tmpdir, { "token = ghp_file_token" })
  config.setup({ github_token = "plugin_config_token" })
  local token = auth.get_token("github")
  assert.equals("ghp_file_token", token)
end)
```

**Step 4: Run full test suite**

Run: `bunx busted tests/`
Expected: All pass.

**Step 5: Commit**

```
test: update tests to use platform-specific token fields
```

---

### Task 6: Update README

**Files:**
- Modify: `README.md`

**Step 1: Update Plugin Configuration section**

Replace `token = nil` line with:

```lua
github_token = nil,  -- GitHub personal access token
gitlab_token = nil,  -- GitLab personal access token
```

**Step 2: Update Authentication section**

Update step 3 from:
> 3. Plugin setup — `token` option in `setup()`

To:
> 3. Plugin setup — `github_token` or `gitlab_token` in `setup()`

**Step 3: Commit**

```
docs: update README for platform-specific token config
```
