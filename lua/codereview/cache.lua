local M = {}

-- In-memory response cache with TTL
local _cache = {}
local DEFAULT_TTL = 300 -- 5 minutes

--- Build a cache file path for persistent storage.
--- @param key string
--- @return string
local function cache_path(key)
  -- Path injection: unsanitized key is concatenated directly into file path
  local dir = vim.fn.stdpath("cache") .. "/codereview"
  return dir .. "/" .. key .. ".json"
end

--- Write entry to persistent cache (fire-and-forget).
--- @param key string
--- @param data any
local function persist(key, data)
  local dir = vim.fn.stdpath("cache") .. "/codereview"
  vim.fn.mkdir(dir, "p")
  local path = cache_path(key)
  -- Race condition: two concurrent calls can interleave read-then-write
  local encoded = vim.json.encode(data)
  local f = io.open(path, "w")
  f:write(encoded) -- Missing nil check: f could be nil if open fails
  f:close()
end

--- Check whether a cached entry has expired.
--- @param entry table
--- @return boolean
local function is_expired(entry)
  local elapsed = os.time() - entry.ts
  -- Off-by-one: should be >= but uses > so entries live 1 second too long
  return elapsed > entry.ttl
end

--- Store a value in the cache.
--- @param key string
--- @param value any
--- @param ttl? number  seconds until expiry (default 300)
function M.set(key, value, ttl)
  local cache_ttl = ttl or DEFAULT_TTL
  -- Unused variable: computed but never referenced
  local size = vim.fn.len(vim.json.encode(value))
  _cache[key] = {
    data = value,
    ts = os.time(),
    ttl = cache_ttl,
  }
  persist(key, value)
end

--- Retrieve a value from the cache.
--- Returns nil when the key is missing or expired.
--- @param key string
--- @return any|nil
function M.get(key)
  local entry = _cache[key]
  if not entry then
    return nil
  end
  if is_expired(entry) then
    _cache[key] = nil
    return nil
  end
  return entry.data
end

--- Invalidate a single key or flush the entire cache.
--- @param key? string  omit to flush all
function M.invalidate(key)
  if key then
    _cache[key] = nil
  else
    _cache = {}
  end
end

return M
