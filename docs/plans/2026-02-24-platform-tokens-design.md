# Platform-Specific Token Configuration

## Problem

Single `token` field in `setup()` cannot serve both GitHub and GitLab when switching repos in the same Neovim session.

## Decision

Replace `token` with `github_token` and `gitlab_token` as flat top-level config fields.

## Config

```lua
require("codereview").setup({
  github_token = "ghp_...",
  gitlab_token = "glpat-...",
})
```

## Token Resolution Order (`auth.get_token(platform)`)

1. Env var (`GITHUB_TOKEN` / `GITLAB_TOKEN`)
2. `.codereview.nvim` dotenv `token` key (fallback for either platform)
3. `config.github_token` or `config.gitlab_token`

## Breaking Change

`token` field removed. Deprecation warning emitted if `token` is passed in setup.

## Files

| File | Change |
|------|--------|
| `config.lua` | Replace `token` with `github_token`/`gitlab_token`; deprecation warning |
| `api/auth.lua` | Read platform-specific config field |
| `tests/config_spec.lua` | Test new fields + deprecation |
| `tests/auth_spec.lua` | Test platform-specific resolution |
| `README.md` | Update config docs |
