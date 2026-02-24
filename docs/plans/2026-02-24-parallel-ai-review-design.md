# Parallel Per-File AI Review

## Problem

For large MRs, AI review runs as a single Claude CLI subprocess. Nothing renders until the entire review completes, leaving users staring at a spinner for minutes.

## Solution

Two-phase review pipeline with progressive rendering. Neovim manages parallelism directly via multiple `jobstart` subprocesses.

## Architecture

```
User presses A (multi-file MR)
       │
Phase 1: Summary Pre-Pass (1 subprocess)
  Input: all diffs
  Output: {file: one-line-summary} JSON
       │
Phase 2: Per-File Reviews (N subprocesses, all at once)
  Each gets: file diff + summaries of other files
  Each outputs: JSON suggestion array
       │
  As each completes → parse + render suggestions immediately
  Spinner: "AI reviewing... 3/8 files"
  Sidebar: suggestion count appears per file
```

Single-file MRs (1 diff) use the existing single-subprocess path unchanged.

## Prompt Design

### Phase 1 — `build_summary_prompt(review, diffs)`

Asks Claude to produce `{"path": "one-line summary"}` for all files. No `--agent` flag. Lightweight call to establish cross-file context.

### Phase 2 — `build_file_review_prompt(review, file, summaries)`

Per-file prompt includes:
- MR title + description
- Other changed files with their summaries (from Phase 1)
- The file's own diff
- Standard review instructions + JSON output format

Uses `--agent code-review`. Same JSON output format as current single-file review.

## Progressive Rendering

On each subprocess completion:
1. Parse JSON suggestions via existing `parse_review_output()`
2. Append to `diff_state.ai_suggestions`
3. Call `place_ai_suggestions()` for that file only (no full re-render)
4. Update spinner counter text
5. Update sidebar with suggestion count for that file
6. When all N complete → `session.ai_finish()`

## Session State Changes

- `ai_job_ids`: table of active job IDs (replaces single `ai_job_id`)
- `ai_total` / `ai_completed`: progress counters
- `ai_start(job_ids, total)`: stores IDs, sets counters, opens spinner
- `ai_file_done()`: increments counter, updates spinner text
- `ai_finish()`: called when `ai_completed == ai_total`, closes spinner

Cancellation (`A` pressed again) calls `jobstop()` on all active job IDs.

## File Changes

| File | Change |
|------|--------|
| `ai/prompt.lua` | Add `build_summary_prompt()`, `build_file_review_prompt()`, `parse_summary_output()` |
| `review/init.lua` | Rewrite multi-file path: two-phase pipeline, N subprocesses, progressive callbacks |
| `review/session.lua` | Add progress counters, multi-job tracking |
| `ui/spinner.lua` | Support dynamic text updates |
| `mr/diff.lua` | Incremental suggestion placement per file |

## Decisions

- **Context level:** File list + AI-generated summaries (not full diffs of other files)
- **Concurrency:** Fire all per-file reviews at once, no limit
- **Progress UX:** Counter in spinner + sidebar file indicators
- **Single-file MRs:** No change to existing path
