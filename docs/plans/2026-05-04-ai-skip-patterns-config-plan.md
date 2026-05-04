# AI Skip Patterns Config Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow per-repo AI skip patterns via `ai_skip_patterns` key in `.codereview.nvim` file.

**Architecture:** Parse comma-separated patterns from dotfile, expose via auth module, merge with Lua config patterns at filter call sites.

**Tech Stack:** Lua, Neovim plugin APIs

---

## Task 1: Add pattern parser to auth.lua

**Files:**
- Modify: `lua/codereview/api/auth.lua:115-118`
- Test: `tests/codereview/auth_skip_patterns_spec.lua` (create)

**Step 1: Write failing test**

Create `tests/codereview/auth_skip_patterns_spec.lua`:

```lua
local auth = require("codereview.api.auth")

describe("auth.get_ai_skip_patterns", function()
  before_each(function()
    auth.reset()
  end)

  it("returns empty table when no config file", function()
    local patterns = auth.get_ai_skip_patterns()
    assert.same({}, patterns)
  end)

  it("parses comma-separated patterns", function()
    -- Mock will be needed; for now test the parse logic
    local parse = auth._parse_skip_patterns_for_test
    local result = parse("*.test.ts,docs/**,*.snap")
    assert.same({ "*.test.ts", "docs/**", "*.snap" }, result)
  end)

  it("trims whitespace around patterns", function()
    local parse = auth._parse_skip_patterns_for_test
    local result = parse("  *.test.ts , docs/** ,*.snap  ")
    assert.same({ "*.test.ts", "docs/**", "*.snap" }, result)
  end)

  it("handles empty string", function()
    local parse = auth._parse_skip_patterns_for_test
    local result = parse("")
    assert.same({}, result)
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/kleist/Sites/codereview.nvim && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/codereview/auth_skip_patterns_spec.lua"`

Expected: FAIL — `get_ai_skip_patterns` and `_parse_skip_patterns_for_test` not defined

**Step 3: Implement in auth.lua**

Add before `return M` (around line 117):

```lua
local function parse_skip_patterns(value)
  if not value or value == "" then
    return {}
  end
  local patterns = {}
  for pat in value:gmatch("[^,]+") do
    local trimmed = pat:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      table.insert(patterns, trimmed)
    end
  end
  return patterns
end

function M.get_ai_skip_patterns()
  local file_config = read_config_file()
  if not file_config or not file_config.ai_skip_patterns then
    return {}
  end
  return parse_skip_patterns(file_config.ai_skip_patterns)
end

M._parse_skip_patterns_for_test = parse_skip_patterns
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/kleist/Sites/codereview.nvim && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/codereview/auth_skip_patterns_spec.lua"`

Expected: PASS

**Step 5: Commit**

```bash
git add lua/codereview/api/auth.lua tests/codereview/auth_skip_patterns_spec.lua
git commit -m "feat(ai): add ai_skip_patterns parser to auth module"
```

---

## Task 2: Update orchestrator.lua to merge patterns

**Files:**
- Modify: `lua/codereview/ai/orchestrator.lua:28-31`

**Step 1: Write failing test**

Create `tests/codereview/ai/orchestrator_skip_patterns_spec.lua`:

```lua
describe("orchestrator skip patterns merge", function()
  local orchestrator = require("codereview.ai.orchestrator")
  local auth = require("codereview.api.auth")
  local config = require("codereview.config")

  before_each(function()
    auth.reset()
  end)

  it("merges dotfile patterns with config patterns", function()
    -- This is an integration concern; verify via file_filter.apply call
    -- The key behavior: both sources should be combined
    local file_filter = require("codereview.ai.file_filter")
    local diffs = {
      { new_path = "src/app.ts", diff = "..." },
      { new_path = "src/app.test.ts", diff = "..." },
    }
    -- With pattern *.test.ts, second file should be filtered
    local result = file_filter.apply(diffs, { "*.test.ts" })
    assert.equals(1, #result)
    assert.equals("src/app.ts", result[1].new_path)
  end)
end)
```

**Step 2: Run test to verify baseline**

Run: `cd /Users/kleist/Sites/codereview.nvim && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/codereview/ai/orchestrator_skip_patterns_spec.lua"`

Expected: PASS (baseline — file_filter works)

**Step 3: Update orchestrator.lua**

Change line 31 from:

```lua
  spec.diffs = file_filter.apply(spec.diffs or {}, (cfg.ai or {}).skip_patterns)
```

To:

```lua
  local auth = require("codereview.api.auth")
  local lua_patterns = (cfg.ai or {}).skip_patterns or {}
  local dotfile_patterns = auth.get_ai_skip_patterns()
  local merged = {}
  for _, p in ipairs(lua_patterns) do table.insert(merged, p) end
  for _, p in ipairs(dotfile_patterns) do table.insert(merged, p) end
  spec.diffs = file_filter.apply(spec.diffs or {}, merged)
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/kleist/Sites/codereview.nvim && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/codereview/ai/orchestrator_skip_patterns_spec.lua"`

Expected: PASS

**Step 5: Commit**

```bash
git add lua/codereview/ai/orchestrator.lua tests/codereview/ai/orchestrator_skip_patterns_spec.lua
git commit -m "feat(ai): merge dotfile skip patterns in orchestrator"
```

---

## Task 3: Update review/init.lua to merge patterns

**Files:**
- Modify: `lua/codereview/review/init.lua:185`

**Step 1: Locate and update**

Change line 185 from:

```lua
  local filtered_diffs = file_filter.apply(diffs, (cfg.ai or {}).skip_patterns)
```

To:

```lua
  local auth = require("codereview.api.auth")
  local lua_patterns = (cfg.ai or {}).skip_patterns or {}
  local dotfile_patterns = auth.get_ai_skip_patterns()
  local merged = {}
  for _, p in ipairs(lua_patterns) do table.insert(merged, p) end
  for _, p in ipairs(dotfile_patterns) do table.insert(merged, p) end
  local filtered_diffs = file_filter.apply(diffs, merged)
```

**Step 2: Run existing tests**

Run: `cd /Users/kleist/Sites/codereview.nvim && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/codereview/"`

Expected: All tests PASS

**Step 3: Commit**

```bash
git add lua/codereview/review/init.lua
git commit -m "feat(ai): merge dotfile skip patterns in review init"
```

---

## Task 4: Extract merge helper to file_filter.lua (DRY)

**Files:**
- Modify: `lua/codereview/ai/file_filter.lua`
- Modify: `lua/codereview/ai/orchestrator.lua`
- Modify: `lua/codereview/review/init.lua`

**Step 1: Add helper to file_filter.lua**

Add before `return M`:

```lua
function M.get_all_skip_patterns()
  local config = require("codereview.config").get()
  local auth = require("codereview.api.auth")
  local lua_patterns = (config.ai or {}).skip_patterns or {}
  local dotfile_patterns = auth.get_ai_skip_patterns()
  local merged = {}
  for _, p in ipairs(lua_patterns) do table.insert(merged, p) end
  for _, p in ipairs(dotfile_patterns) do table.insert(merged, p) end
  return merged
end
```

**Step 2: Simplify orchestrator.lua call site**

Replace the merge logic with:

```lua
  spec.diffs = file_filter.apply(spec.diffs or {}, file_filter.get_all_skip_patterns())
```

**Step 3: Simplify review/init.lua call site**

Replace the merge logic with:

```lua
  local filtered_diffs = file_filter.apply(diffs, file_filter.get_all_skip_patterns())
```

**Step 4: Run all tests**

Run: `cd /Users/kleist/Sites/codereview.nvim && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/codereview/"`

Expected: All tests PASS

**Step 5: Commit**

```bash
git add lua/codereview/ai/file_filter.lua lua/codereview/ai/orchestrator.lua lua/codereview/review/init.lua
git commit -m "refactor(ai): extract get_all_skip_patterns helper to file_filter"
```

---

## Task 5: Update README documentation

**Files:**
- Modify: `README.md` (configuration section)

**Step 1: Find config docs section**

Search for existing `.codereview.nvim` documentation in README.

**Step 2: Add ai_skip_patterns docs**

Add to the `.codereview.nvim` section:

```markdown
### AI Skip Patterns

Skip specific files from AI review by adding patterns to `.codereview.nvim`:

```
ai_skip_patterns=*.test.ts,docs/**,*.snap,fixtures/**
```

Patterns are comma-separated globs, merged with plugin config `ai.skip_patterns` and built-in defaults (lockfiles, minified files, generated code, vendor directories).
```

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add ai_skip_patterns configuration"
```

---

## Summary

| Task | Description | Deps |
|------|-------------|------|
| 1 | Parser in auth.lua + tests | — |
| 2 | Merge in orchestrator.lua | 1 |
| 3 | Merge in review/init.lua | 1 |
| 4 | Extract DRY helper | 2, 3 |
| 5 | README docs | 4 |
