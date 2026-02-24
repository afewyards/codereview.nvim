# Graceful curl error handling

## Problem

`plenary.curl.request()` throws Lua errors on network failures (timeouts, DNS, connection refused). No `pcall` wraps these calls in `client.lua`, so errors propagate as unhandled tracebacks that crash the plugin.

## Solution

Add `safe_request(params)` helper in `client.lua` — wraps `curl.request` with `pcall`, returns `(nil, error_string)` on throw. Matches existing error convention so all callers handle it naturally.

## Changes

**Single file:** `lua/codereview/api/client.lua`

### New helper

```lua
local function safe_request(params)
  local ok, response = pcall(curl.request, params)
  if not ok then
    return nil, response  -- response is the error string on pcall failure
  end
  return response
end
```

### Replacements

Replace all bare `curl.request(params)` calls with `safe_request(params)`:

- `M.request` — lines 100, 113 (rate-limit retry)
- `M.async_request` — lines 141, 156 (rate-limit retry), via `async_util.wrap`
- `M.get_url` — line 199

For async calls, wrap the `async_util.wrap(curl.request, 2)(params)` pattern similarly.

### What stays the same

- Callers already handle `(nil, err)` — no upstream changes
- Error messages flow through existing `vim.notify` in `mr/list.lua`, `mr/detail.lua`, etc.
- Rate-limit handling, pagination unchanged
