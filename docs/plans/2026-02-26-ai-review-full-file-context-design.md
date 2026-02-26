# AI Review: Full File Context

## Problem

AI per-file review only receives the unified diff. Without the full file, the AI lacks surrounding context (imports, function signatures, class structure) needed to catch issues like unused imports, type mismatches, or broken call sites outside the diff hunks.

## Decision

Send the full HEAD file content alongside the diff in per-file review prompts. The AI reviews only the diff but uses the full file for context.

## Design

### Data Flow

```
User triggers AI review (per-file)
  → review/init.lua: for each non-deleted file
    → provider.get_file_content(client, ctx, head_sha, path)
    → check line count vs ai.max_file_size
    → prompt.build_file_review_prompt(review, file, summaries, content)
    → subprocess.run(prompt)
```

### Changes

**providers/github.lua** — `get_file_content(client, ctx, ref, path)`
- `GET /repos/{owner}/{repo}/contents/{path}?ref={ref}`
- Decode base64, return string or nil

**providers/gitlab.lua** — `get_file_content(client, ctx, ref, path)`
- `GET /projects/{id}/repository/files/{url_encoded_path}/raw?ref={ref}`
- Return raw text or nil

**config.lua** — `ai.max_file_size = 500`
- Line limit; exceeding → skip content, diff-only

**review/init.lua** — Phase 2 per-file loop
- Fetch content lazily before building each prompt
- Skip for deleted files and files exceeding max_file_size

**ai/prompt.lua** — `build_file_review_prompt(review, file, summaries, content)`
- Add `## Full File Content` section before diff when content present
- Instruction: "Full file for context only. Review the diff changes only."

### Unchanged
- `build_summary_prompt` — diff-only (no content)
- `build_review_prompt` — single-file mode unchanged
- `normalize_file_diff` — no new fields (content fetched separately)
- Subprocess/parsing — no changes

### Error Handling
- Fetch failure → diff-only, log warning
- File too large → skip content
- Deleted files → skip fetch
