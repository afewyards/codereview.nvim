--- Simple TTL cache for API responses.
local M = {}

---@class CacheEntry
---@field value any
---@field expires_at number

---@type table<string, CacheEntry>
local store = {}

--- Store a value with a time-to-live in seconds.
---@param key string
---@param value any
---@param ttl_seconds number
function M.set(key, value, ttl_seconds)
  store[key] = {
    value = value,
    expires_at = os.time() + ttl_seconds,
  }
end

--- Retrieve a cached value.  Returns nil if expired or absent.
---@param key string
---@return any|nil
function M.get(key)
  local entry = store[key]
  if not entry then return nil end
  if os.time() > entry.expires_at then
    store[key] = nil
    return nil
  end
  return entry.value
end

--- Remove a single key from the cache.
---@param key string
function M.invalidate(key)
  store[key] = nil
end

--- Flush all cached entries.
function M.flush()
  store = {}
end

--- Return the number of live (non-expired) entries.
---@return number
function M.size()
  local count = 0
  local now = os.time()
  for k, entry in pairs(store) do
    if now > entry.expires_at then
      store[k] = nil
    else
      count = count + 1
    end
  end
  return count
end

--- Wrap an expensive function with caching.
---@param fn fun(...): any
---@param key_fn fun(...): string   Function that derives the cache key from args
---@param ttl number               TTL in seconds
---@return fun(...): any
function M.memoize(fn, key_fn, ttl)
  return function(...)
    local key = key_fn(...)
    local cached = M.get(key)
    if cached ~= nil then return cached end
    local result = fn(...)
    if result ~= nil then
      M.set(key, result, ttl)
    end
    return result
  end
end

return M
