local M = {}

M.DEFAULT_PATTERNS = {
  "*.lock",
  "package-lock.json",
  "yarn.lock",
  "pnpm-lock.yaml",
  "Cargo.lock",
  "Gemfile.lock",
  "poetry.lock",
  "uv.lock",
  "go.sum",
  "composer.lock",
  "Pipfile.lock",
  "*.min.js",
  "*.min.css",
  "*.map",
  "*.pb.go",
  "*_pb2.py",
  "*.generated.*",
  "node_modules/**",
  "vendor/**",
  "third_party/**",
  "dist/**",
  "build/**",
  ".next/**",
}

--- Convert a glob pattern to a Lua pattern.
--- Rules: escape magic chars, ** → .*, * → [^/]*, ? → [^/]
---@param glob string
---@return string
local function glob_to_pat(glob)
  local pat = glob:gsub("([%%%.%(%)%[%]%+%-%^%$])", "%%%1")
  pat = pat:gsub("%*%*", "\0DBL\0"):gsub("%*", "[^/]*"):gsub("%?", "[^/]"):gsub("\0DBL\0", ".*")
  return "^" .. pat .. "$"
end

---@param path string
---@param globs string[]
---@return boolean
local function matches_any(path, globs)
  local base = path:match("([^/]+)$") or path
  for _, g in ipairs(globs) do
    local pat = glob_to_pat(g)
    if path:match(pat) or base:match(pat) then
      return true
    end
  end
  return false
end

---@param diff string?
---@return boolean
local function is_binary_diff(diff)
  return diff ~= nil and diff:find("\nBinary files ", 1, true) ~= nil
end

--- Filter diffs, removing lockfiles, generated files, vendored dirs, and binary diffs.
---@param diffs table[]  list of {new_path, old_path, diff}
---@param user_patterns string[]?  additional glob patterns to skip
---@return table[]
function M.apply(diffs, user_patterns)
  local globs = {}
  for _, g in ipairs(M.DEFAULT_PATTERNS) do
    table.insert(globs, g)
  end
  for _, g in ipairs(user_patterns or {}) do
    table.insert(globs, g)
  end

  local out = {}
  for _, f in ipairs(diffs) do
    local path = f.new_path or f.old_path
    if path and not matches_any(path, globs) and not is_binary_diff(f.diff) then
      table.insert(out, f)
    end
  end
  return out
end

return M
