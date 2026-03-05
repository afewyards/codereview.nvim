# Mock/Demo Provider Guide

Reference document for implementing a `demo` platform provider and a mock AI
provider. Covers every interface contract with exact file paths, line numbers,
and data shapes.

---

## 1. Provider Interface

### How providers are loaded

`lua/codereview/providers/init.lua` is the only dispatch point.

```
M.get_provider(platform)   -- line 11
```

It does a literal `require("codereview.providers.<platform>")`. Valid strings
today are `"gitlab"` and `"github"`. To add `"demo"` you need:

1. A file at `lua/codereview/providers/demo.lua`
2. One branch in `M.get_provider` (lines 12-18):
   ```lua
   elseif platform == "demo" then
     return require("codereview.providers.demo")
   ```
3. Optionally a matching entry in `M.detect_platform` (line 5) or set
   `config.platform = "demo"` from the user's setup call — that short-circuits
   detection entirely (line 37):
   ```lua
   local platform = config.platform or M.detect_platform(host)
   ```

`M.detect()` (line 21) returns `provider, ctx, err`.
`ctx` is always `{ base_url, project, host, platform }`.

---

### Required provider functions

Every function that callers invoke is listed below.  All callers are in the
main branch (`lua/`).  Signatures follow the pattern
`fn(client, ctx, ...)` where `client` is `codereview.api.client` and `ctx`
is the detect context above.

| Function | Callers | Returns |
|---|---|---|
| `list_reviews(client, ctx, opts)` | `mr/list.lua:50` | `reviews[], err` |
| `get_review(client, ctx, id)` | `mr/detail.lua:424` | `review, err` |
| `get_diffs(client, ctx, review)` | `mr/detail.lua:433`, `mr/diff.lua:81` | `diffs[], err` |
| `get_discussions(client, ctx, review)` | `mr/detail.lua:427` | `discussions[], err` |
| `get_file_content(client, ctx, ref, path)` | diff_render (via state) | `string, err` |
| `post_comment(client, ctx, review, body, position)` | actions | `result, err` |
| `post_range_comment(client, ctx, review, body, old_path, new_path, start_pos, end_pos)` | actions | `result, err` |
| `reply_to_discussion(client, ctx, review, disc_id, body)` | actions | `result, err` |
| `edit_note(client, ctx, review, disc_id, note_id, body)` | actions | `result, err` |
| `delete_note(client, ctx, review, disc_id, note_id)` | actions | `result, err` |
| `resolve_discussion(client, ctx, review, disc_id, resolved[, node_id])` | actions | `result, err` |
| `approve(client, ctx, review)` | actions | `result, err` |
| `unapprove(client, ctx, review)` | actions | `result, err` |
| `get_current_user(client, ctx)` | `mr/detail.lua:466`, `mr/diff.lua:102` | `username_string, err` |
| `merge(client, ctx, review, opts)` | actions | `result, err` |
| `close(client, ctx, review)` | actions | `result, err` |
| `create_review(client, ctx, params)` | `mr/create.lua` | `result, err` |
| `create_draft_comment(client, ctx, review, params)` | review/drafts | `result, err` |
| `get_pending_review_drafts(client, ctx, review)` OR `get_draft_notes(client, ctx, review)` | `review/drafts.lua` | `drafts[], err` |
| `delete_draft_note(client, ctx, review, draft_id)` | drafts | `result, err` |
| `publish_review(client, ctx, review, opts)` | `review/submit.lua` | `result, err` |
| `build_auth_header(token[, token_type])` | auth module | `headers_table` |

**Minimum viable set for demo** (read-only navigation, no posting):
`list_reviews`, `get_review`, `get_diffs`, `get_discussions`,
`get_file_content`, `get_current_user`.

Stub all write functions to return `nil, "not supported"`.

---

## 2. Existing Provider Structure (GitHub as canonical example)

File: `lua/codereview/providers/github.lua`

```lua
local types = require("codereview.providers.types")
local log   = require("codereview.log")
local M     = {}

M.name     = "github"    -- string identifier, used for logging
M.base_url = "https://api.github.com"  -- informational only

-- Each provider function follows this pattern:
function M.list_reviews(client, ctx, opts)
  -- ... build headers, call client.get / client.paginate_all ...
  -- ... normalize raw API response via types.normalize_review() ...
  return reviews, nil        -- success: table + nil
  -- OR
  return nil, "error string" -- failure: nil + string
end

return M
```

There is no interface table or metatable — it is a plain module table. The
dispatcher `require()`s it and the caller uses duck typing.

---

## 3. Data Shapes

### 3a. Review (normalized MR/PR object)

Defined in `lua/codereview/providers/types.lua:3`, produced by
`types.normalize_review(raw)`:

```lua
{
  id               = <number>,          -- MR iid / PR number
  title            = <string>,
  author           = <string>,          -- username string
  source_branch    = <string>,
  target_branch    = <string>,
  state            = <string>,          -- "opened"/"open"/"merged"/"closed"
  base_sha         = <string|nil>,
  head_sha         = <string|nil>,
  start_sha        = <string|nil>,
  web_url          = <string>,
  description      = <string>,
  pipeline_status  = <string|nil>,      -- "success"/"failed"/"running" etc.
  approved_by      = <string[]>,        -- list of usernames
  approvals_required = <number>,
  sha              = <string|nil>,      -- same as head_sha in practice
  merge_status     = <string|nil>,      -- "can_be_merged" / "cannot_be_merged"
}
```

### 3b. File diff object

Returned as an array element by `get_diffs()`. Defined in
`lua/codereview/providers/types.lua:46` via `types.normalize_file_diff(raw)`:

```lua
{
  diff         = <string>,   -- raw unified diff text (the patch), NOT parsed
  new_path     = <string>,   -- file path in the new tree
  old_path     = <string>,   -- file path in the old tree
  renamed_file = <boolean>,
  new_file     = <boolean>,
  deleted_file = <boolean>,
}
```

The `diff` field is **raw unified diff text** — standard `--- a/...` / `+++ b/...`
hunk format. It is fed directly to `prompt.annotate_diff_with_lines()` and to
the diff renderer.

### 3c. Discussion object

Returned as an array element by `get_discussions()`.
The authoritative shape after normalization (GitLab:
`lua/codereview/providers/gitlab.lua:111`, GitHub:
`lua/codereview/providers/github.lua:140`):

```lua
{
  id       = <string>,         -- opaque discussion ID
  resolved = <boolean>,
  notes    = {
    {
      id          = <number|string>,
      author      = <string>,          -- username
      body        = <string>,          -- markdown text
      created_at  = <string>,          -- ISO8601
      system      = <boolean>,         -- true = system event (auto-generated)
      resolvable  = <boolean>,
      resolved    = <boolean>,
      resolved_by = <string|nil>,
      position    = {                  -- nil for non-inline (general) notes
        new_path  = <string|nil>,
        old_path  = <string|nil>,
        new_line  = <number|nil>,
        old_line  = <number|nil>,
        -- GitLab extras:
        base_sha  = <string|nil>,
        head_sha  = <string|nil>,
        start_sha = <string|nil>,
        start_new_line = <number|nil>, -- range start (GitLab)
        start_old_line = <number|nil>,
        -- GitHub extras:
        side          = <string|nil>,  -- "LEFT"/"RIGHT"
        start_line    = <number|nil>,
        start_side    = <string|nil>,
        commit_sha    = <string|nil>,
        outdated      = <boolean>,
      },
    },
    -- ... more notes (replies) ...
  },
}
```

Inline discussions have `notes[1].position ~= nil`.
General (non-inline) discussions have `notes[1].position == nil`.
System notes have `notes[1].system == true`.

---

## 4. Provider Selection Flow

```
config.setup({ platform = "demo" })   -- or left nil for auto-detect
  └─> providers.detect()              -- init.lua:21
        ├─ config.platform = "demo"   -- skips detect_platform()
        ├─ M.get_provider("demo")     -- init.lua:11
        │    └─ require("codereview.providers.demo")
        └─ returns provider, ctx, nil
```

Auto-detect path (no explicit platform):
```
git remote url → git.parse_remote() → host string
  └─ detect_platform(host)           -- init.lua:5
       ├─ "github.com" → "github"
       └─ anything else → "gitlab"
```

The `ctx` table passed to every provider function:
```lua
{
  base_url = <string>,  -- e.g. "https://api.github.com" or "https://gitlab.com"
  project  = <string>,  -- e.g. "owner/repo" or "group/subgroup/project"
  host     = <string>,  -- e.g. "github.com"
  platform = <string>,  -- "github" | "gitlab" | "demo"
}
```

---

## 5. AI CLI Integration (claude_cli provider)

File: `lua/codereview/ai/providers/claude_cli.lua`

### Command invoked

```lua
-- build_cmd() line 5:
local cmd = { claude_cmd, "-p" }        -- e.g. {"claude", "-p"}
-- if agent configured:
table.insert(cmd, "--agent")
table.insert(cmd, agent)                -- e.g. "code-review"
```

So the actual shell command is:
```
claude -p [--agent <agent>]
```

The **prompt is sent via stdin** (`vim.fn.chansend`, line 82).
The **response is read from stdout** (`stdout_buffered = true`, line 33).

`M.run(prompt, callback, opts)` (line 14):
- `prompt` — string, the full prompt text
- `callback(output, err)` — called with stdout string on success, or
  `(nil, error_string)` on failure
- `opts.skip_agent` — boolean, suppresses the `--agent` flag (used for summary
  generation, `ai/summary.lua:102`)

The raw stdout string is passed directly to `prompt.parse_review_output()`.

### AI output format expected by the plugin

`lua/codereview/ai/prompt.lua:209` (`parse_review_output`):

The AI must return a fenced JSON block:

````
```json
[
  {
    "file":     "path/to/file.lua",
    "line":     42,
    "code":     "exact source line content (no +/- prefix)",
    "severity": "error" | "warning" | "info" | "suggestion",
    "comment":  "text, use \\n for newlines"
  },
  ...
]
```
````

Fallback: a bare JSON array `[...]` anywhere in the output is also accepted
(line 218 greedy match).

If no issues: `[]` (empty array).

### Parsed suggestion object (internal representation)

After `parse_review_output()` returns (line 239):

```lua
{
  file     = <string>,     -- relative file path, matches diff.new_path
  line     = <number>,     -- new-file line number (from L-prefix in annotated diff)
  code     = <string|nil>, -- trimmed source text of the commented line
  severity = <string>,     -- "error"|"warning"|"info"|"suggestion"
  comment  = <string>,     -- may contain literal \n newlines
  status   = "pending",    -- always "pending" on creation; later "accepted"/"dismissed"
}
```

---

## 6. Picker Integration

### pick_mr entries

`mr/list.lua:22` (`format_mr_entry(review)`) produces picker entries:

```lua
{
  display       = <string>,  -- formatted display line (icon + #id + title + author + branch)
  id            = <number>,  -- review.id
  title         = <string>,
  author        = <string>,
  source_branch = <string>,
  target_branch = <string>,
  web_url       = <string>,
  review        = <review>,  -- full normalized review object (see §3a)
}
```

`picker/init.lua:37` calls `adapter.pick_mr(entries, on_select)`.
`on_select` receives the full entry table.

In Telescope (`picker/telescope.lua:16`):
- `entry.display` → shown in picker
- `entry.title .. " " .. entry.author .. " " .. tostring(entry.id)` → ordinal for fuzzy search

In fzf-lua (`picker/fzf.lua:9`): `entry.display` is the display string;
selection is resolved back to entry via a display→entry map.

### pick_files entries

Built in `mr/diff_sidebar.lua` (or wherever `pick_files` is called).
Required fields: `display` (string), `ordinal` (string).
The entry itself is passed to `on_select`.

### pick_comments entries

`picker/comments.lua:10` (`build_entries`):

```lua
-- Discussion entry:
{
  type      = "discussion",
  display   = <string>,       -- "💬 [status] path:line  @author: body..."
  ordinal   = <string>,
  discussion = <discussion>,  -- full discussion object
  file_path  = <string>,
  line       = <number|nil>,
  file_idx   = <number|nil>,  -- index into state.files array
}

-- AI suggestion entry:
{
  type       = "ai_suggestion",
  display    = <string>,      -- "🤖 [severity] path:line  comment..."
  ordinal    = <string>,
  suggestion = <suggestion>,  -- parsed suggestion object (see §5)
  file_path  = <string>,
  line       = <number|nil>,
  file_idx   = <number|nil>,
}
```

---

## 7. get_diffs() Return Format (Detail)

`get_diffs(client, ctx, review)` returns `diffs[], err`.

`diffs` is a Lua array where each element is a file-diff object (§3b).
The `diff` field is the **raw unified diff patch string** for that file only —
not the full multi-file diff. Example:

```
@@ -10,6 +10,7 @@
 context line
-removed line
+added line
 context line
```

This is passed as-is to:
- `prompt.annotate_diff_with_lines(file.diff)` — adds `L N:` prefixes
- `prompt.extract_changed_lines(file.diff)` — finds `+` line numbers
- `diff_render.render_file_diff(...)` — visual renderer

For a demo provider, generate synthetic unified diff strings in this format.

---

## 8. Draft Comment Shape

For providers that support server-side drafts, `get_pending_review_drafts()`
(GitHub, `github.lua:571`) and `get_draft_notes()` (GitLab, `gitlab.lua:362`)
both return an array of draft objects shaped like a discussion with a single
note, plus extra fields:

```lua
{
  notes = {{
    author     = "You (draft)",
    body       = <string>,
    created_at = <string>,
    position   = <position|nil>,
  }},
  is_draft       = true,
  server_draft_id = <number|string>,
}
```

For a demo provider, `get_pending_review_drafts` / `get_draft_notes` can
return `{}` (empty array).

---

## 9. Minimal Demo Provider Skeleton

```lua
-- lua/codereview/providers/demo.lua
local types = require("codereview.providers.types")
local M = {}

M.name = "demo"

-- Auth stub (required by auth module checks in some paths)
function M.build_auth_header(_token) return {} end

-- ── Read-only interface ───────────────────────────────────────────────────────

function M.list_reviews(_client, _ctx, _opts)
  return {
    types.normalize_review({
      id             = 1,
      title          = "Demo: add widget feature",
      author         = "alice",
      source_branch  = "feat/widget",
      target_branch  = "main",
      state          = "opened",
      head_sha       = "abc123",
      base_sha       = "def456",
      start_sha      = "def456",
      web_url        = "https://example.com/demo/1",
      description    = "Adds the new widget component.",
      pipeline_status = "success",
      approved_by    = {},
      approvals_required = 1,
    }),
  }, nil
end

function M.get_review(_client, _ctx, _id)
  -- return same shape as list_reviews element
  return M.list_reviews()[1], nil
end

function M.get_diffs(_client, _ctx, _review)
  return {
    {
      new_path     = "src/widget.lua",
      old_path     = "src/widget.lua",
      new_file     = false,
      renamed_file = false,
      deleted_file = false,
      diff         = "@@ -1,3 +1,6 @@\n local M = {}\n+\n+function M.render()\n+  return \"<widget />\"\n+end\n+\n return M\n",
    },
  }, nil
end

function M.get_discussions(_client, _ctx, _review)
  return {
    {
      id       = "disc-1",
      resolved = false,
      notes    = {{
        id         = 1,
        author     = "bob",
        body       = "Should this be configurable?",
        created_at = "2026-02-28T10:00:00Z",
        system     = false,
        resolvable = true,
        resolved   = false,
        position   = {
          new_path = "src/widget.lua",
          old_path = "src/widget.lua",
          new_line = 3,
          old_line = nil,
        },
      }},
    },
  }, nil
end

function M.get_file_content(_client, _ctx, _ref, _path)
  return "local M = {}\n\nfunction M.render()\n  return \"<widget />\"\nend\n\nreturn M\n", nil
end

function M.get_current_user(_client, _ctx)
  return "demo-user", nil
end

-- ── Write stubs ───────────────────────────────────────────────────────────────

local function not_supported() return nil, "not supported in demo mode" end

M.post_comment             = not_supported
M.post_range_comment       = not_supported
M.reply_to_discussion      = not_supported
M.edit_note                = not_supported
M.delete_note              = not_supported
M.resolve_discussion       = not_supported
M.approve                  = not_supported
M.unapprove                = not_supported
M.merge                    = not_supported
M.close                    = not_supported
M.create_review            = not_supported
M.create_draft_comment     = not_supported
M.get_pending_review_drafts = function() return {} end
M.get_draft_notes          = function() return {} end
M.delete_draft_note        = not_supported
M.publish_review           = not_supported

return M
```

To wire it in, add to `lua/codereview/providers/init.lua` line 16:
```lua
elseif platform == "demo" then
  return require("codereview.providers.demo")
```

And in user config:
```lua
require("codereview").setup({ platform = "demo" })
```

---

## 10. Mock AI Provider Skeleton

The AI provider dispatch is in `lua/codereview/ai/providers/init.lua`.
`valid_providers` map (line 3) only accepts hardcoded names. To add `"demo"`:

```lua
-- in ai/providers/init.lua, add to valid_providers:
demo = "codereview.ai.providers.demo",
```

Then create `lua/codereview/ai/providers/demo.lua`:

```lua
local M = {}

-- Matches the interface of claude_cli: M.run(prompt, callback, opts)
-- callback(output_string) on success
-- callback(nil, error_string) on failure
function M.run(_prompt, callback, _opts)
  -- Return a canned JSON response that parse_review_output() can parse
  local fake_output = [[
```json
[
  {
    "file": "src/widget.lua",
    "line": 3,
    "code": "function M.render()",
    "severity": "suggestion",
    "comment": "Consider accepting an options table for future extensibility."
  }
]
```
]]
  -- schedule to simulate async behavior
  vim.schedule(function()
    callback(fake_output)
  end)
end

return M
```

User config:
```lua
require("codereview").setup({
  platform = "demo",
  ai = { provider = "demo" },
})
```

Note: `config.lua:48` validates `ai.provider` against a hardcoded whitelist and
resets unknown values to `"claude_cli"`. You must also add `"demo"` to
`valid_providers` in `config.lua:48`:
```lua
local valid_providers = {
  claude_cli = true, anthropic = true, openai = true,
  ollama = true, custom_cmd = true, demo = true,
}
```
