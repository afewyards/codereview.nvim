# Timeout Error Handling Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Wrap `curl.request` calls with `pcall` so network failures (timeouts, DNS, connection refused) return `(nil, err)` instead of crashing with a Lua traceback.

**Architecture:** Add a `safe_request` local helper in `client.lua` that wraps `curl.request` with `pcall`. Replace all 5 bare `curl.request()` call sites. For async, wrap the `async_util.wrap(curl.request, 2)()` pattern similarly.

**Tech Stack:** Lua, plenary.curl, plenary.async, busted (tests)

---

### Task 1: Test — sync `safe_request` catches thrown errors

**Files:**
- Modify: `tests/unit_helper.lua` (make plenary.curl stub configurable)
- Modify: `tests/codereview/api/client_spec.lua`

**Step 1: Make plenary.curl stub throwable**

In `tests/unit_helper.lua`, replace the `plenary.curl` preload (lines 402-412) so tests can override `request`:

```lua
local _plenary_curl_stub = {
  get = function() end,
  post = function() end,
  patch = function() end,
  delete = function() end,
  request = function()
    return { status = 200, body = vim.json.encode({}) }
  end,
}

package.preload["plenary.curl"] = function()
  return _plenary_curl_stub
end

-- Expose for test overrides
_G._plenary_curl_stub = _plenary_curl_stub
```

**Step 2: Write failing tests**

In `tests/codereview/api/client_spec.lua`, add a new `describe` block:

```lua
describe("request error handling", function()
  local orig_request

  before_each(function()
    orig_request = _G._plenary_curl_stub.request
  end)

  after_each(function()
    _G._plenary_curl_stub.request = orig_request
  end)

  it("returns nil and error when curl.request throws", function()
    _G._plenary_curl_stub.request = function()
      error("Timeout was reached")
    end
    local result, err = client.request("get", "https://api.example.com", "/test", {
      headers = { ["Authorization"] = "Bearer test" },
    })
    assert.is_nil(result)
    assert.truthy(err:find("Timeout was reached"))
  end)

  it("returns nil and error when curl.request throws on rate-limit retry", function()
    local call_count = 0
    _G._plenary_curl_stub.request = function()
      call_count = call_count + 1
      if call_count == 1 then
        return { status = 429, headers = { ["retry-after"] = "0" }, body = "" }
      end
      error("Connection refused")
    end
    local result, err = client.request("get", "https://api.example.com", "/test", {
      headers = { ["Authorization"] = "Bearer test" },
    })
    assert.is_nil(result)
    assert.truthy(err:find("Connection refused"))
  end)
end)
```

**Step 3: Run tests to verify they fail**

Run: `bunx busted tests/codereview/api/client_spec.lua`
Expected: FAIL — errors propagate as unhandled tracebacks.

**Step 4: Commit**

```
test(api): add tests for curl request error handling
```

---

### Task 2: Implement `safe_request` wrapper in `client.lua`

**Files:**
- Modify: `lua/codereview/api/client.lua`

**Step 1: Add `safe_request` helper after `process_response` (after line 82)**

```lua
local function safe_request(params)
  local ok, response = pcall(curl.request, params)
  if not ok then
    return nil, tostring(response)
  end
  return response
end
```

**Step 2: Replace `curl.request(params)` in `M.request` (line 100)**

```lua
-- Before:
local response = curl.request(params)
-- After:
local response, curl_err = safe_request(params)
if not response and curl_err then
  log.error(string.format("REQ %s %s — %s", method:upper(), params.url, curl_err))
  return nil, "Request failed: " .. curl_err
end
```

**Step 3: Replace `curl.request(params)` in rate-limit retry (line 113)**

```lua
-- Before:
response = curl.request(params)
-- After:
local retry_err
response, retry_err = safe_request(params)
if not response and retry_err then
  log.error(string.format("REQ %s %s — retry failed: %s", method:upper(), params.url, retry_err))
  return nil, "Request failed: " .. retry_err
end
```

**Step 4: Replace `curl.request(params)` in `M.get_url` (line 199)**

```lua
-- Before:
local response = curl.request(params)
-- After:
local response, curl_err = safe_request(params)
if not response and curl_err then
  return nil, "Request failed: " .. curl_err
end
```

**Step 5: Replace async calls in `M.async_request` (lines 141, 156)**

Wrap the async pattern similarly. Add an async-safe wrapper:

```lua
local function safe_async_request(params)
  local ok, response = pcall(async_util.wrap(curl.request, 2), params)
  if not ok then
    return nil, tostring(response)
  end
  return response
end
```

Replace line 141:
```lua
local response, curl_err = safe_async_request(params)
if not response and curl_err then
  log.error(string.format("ASYNC REQ %s %s — %s", method:upper(), params.url, curl_err))
  return nil, "Request failed: " .. curl_err
end
```

Replace line 156 (rate-limit retry):
```lua
local retry_err
response, retry_err = safe_async_request(params)
if not response and retry_err then
  log.error(string.format("ASYNC REQ %s %s — retry failed: %s", method:upper(), params.url, retry_err))
  return nil, "Request failed: " .. retry_err
end
```

**Step 6: Run tests**

Run: `bunx busted tests/codereview/api/client_spec.lua`
Expected: ALL PASS

**Step 7: Commit**

```
fix(api): wrap curl.request with pcall to handle network errors gracefully
```

---

### Task 3: Test — `get_url` error handling

**Files:**
- Modify: `tests/codereview/api/client_spec.lua`

**Step 1: Add test for `get_url` throwing**

```lua
describe("get_url error handling", function()
  local orig_request

  before_each(function()
    orig_request = _G._plenary_curl_stub.request
  end)

  after_each(function()
    _G._plenary_curl_stub.request = orig_request
  end)

  it("returns nil and error when curl throws during get_url", function()
    _G._plenary_curl_stub.request = function()
      error("Could not resolve host")
    end
    local result, err = client.get_url("https://api.example.com/items", {
      headers = { ["Authorization"] = "Bearer test" },
    })
    assert.is_nil(result)
    assert.truthy(err:find("Could not resolve host"))
  end)
end)
```

**Step 2: Run tests**

Run: `bunx busted tests/codereview/api/client_spec.lua`
Expected: ALL PASS (implementation from Task 2 covers this)

**Step 3: Commit**

```
test(api): add get_url network error handling test
```
