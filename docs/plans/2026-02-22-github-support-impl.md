# GitHub Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add GitHub PR support alongside existing GitLab MR support, rename plugin from `glab_review` to `codereview`, introduce a provider abstraction layer.

**Architecture:** Provider interface (`providers/gitlab.lua`, `providers/github.lua`) encapsulates all platform-specific API calls. Existing modules call provider methods instead of raw HTTP. Platform auto-detected from git remote URL.

**Tech Stack:** Lua, plenary.nvim (HTTP + async), Neovim 0.10+

**Design:** [github-support-design.md](2026-02-22-github-support-design.md)

## Phases

| Phase | Tasks | Plan |
|-------|-------|------|
| **1. Rename** | Task 1 — `glab_review` → `codereview`. Pure mechanical, no logic. | [phase-1-rename.md](2026-02-22-github-phase-1-rename.md) |
| **2. Provider layer** | Tasks 2-7 — Types, detection, providers, auth, client. **Additive only.** | [phase-2-providers.md](2026-02-22-github-phase-2-providers.md) |
| **3. Wire up + integrate** | Tasks 8-16 — Rewire modules, update field access, delete dead code, `.codereview.json`, integration tests. | [phase-3-wiring.md](2026-02-22-github-phase-3-wiring.md) |

## Parallelism Map

```
Phase 2:
  Wave A (parallel): Task 2 (types) + Task 6 (auth) + Task 7 (client)
  Wave B (parallel, after 2): Task 4 (gitlab) + Task 5 (github)
  Wave C (after 4+5): Task 3 (detection)

Phase 3:
  Wave D (parallel): Task 8 (list) + Task 11 (comment) + Task 12 (actions) + Task 15 (.codereview.json)
  Wave E (after 8): Task 9 (detail) + Task 10a (picker)
  Wave F (after 9+11): Task 10 (diff)
  Wave G (after all): Task 13 (init) → Task 14 (delete endpoints) → Task 16 (integration tests)
```

## Normalized Data Shapes (reference)

| Normalized | Was (GitLab raw) | Notes |
|---|---|---|
| `review.id` | `mr.iid` | Display as `#%d` (not `MR !%d`) |
| `review.author` | `mr.author.username` | **String**, not `{ username }` table |
| `review.base_sha` | `mr.diff_refs.base_sha` | Flat, not nested |
| `review.head_sha` | `mr.diff_refs.head_sha` | Flat |
| `review.start_sha` | `mr.diff_refs.start_sha` | GitLab-only; GitHub sets to `base_sha` |
| `review.pipeline_status` | `mr.head_pipeline.status` | String or nil |
| `review.approved_by` | `mr.approved_by[].user.username` | **List of strings**, not list of tables |
| `note.author` | `note.author.username` | **String**, not table |
| `note.resolved_by` | `note.resolved_by.username` | **String or nil**, not table |
| `entry.id` | `entry.iid` | |
| `entry.review` | `entry.mr` | Full normalized review object |
