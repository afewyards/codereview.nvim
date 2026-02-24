```
 ██████╗ ██████╗ ██████╗ ███████╗
██╔════╝██╔═══██╗██╔══██╗██╔════╝
██║     ██║   ██║██║  ██║█████╗
██║     ██║   ██║██║  ██║██╔══╝
╚██████╗╚██████╔╝██████╔╝███████╗
 ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝
██████╗ ███████╗██╗   ██╗██╗███████╗██╗    ██╗
██╔══██╗██╔════╝██║   ██║██║██╔════╝██║    ██║
██████╔╝█████╗  ██║   ██║██║█████╗  ██║ █╗ ██║
██╔══██╗██╔══╝  ╚██╗ ██╔╝██║██╔══╝  ██║███╗██║
██║  ██║███████╗ ╚████╔╝ ██║███████╗╚███╔███╔╝
╚═╝  ╚═╝╚══════╝  ╚═══╝  ╚═╝╚══════╝ ╚══╝╚══╝
```

# codereview.nvim

## Review pull requests and merge requests without leaving Neovim

https://github.com/user-attachments/assets/e805a264-edf7-47ab-ab4d-5a2361826131

> **Note: This project is in active development.** Core features are operational, but some areas are still being refined. Please report issues or unexpected behavior via [GitHub Issues](https://github.com/afewyards/codereview.nvim/issues).

## Features

- **GitHub + GitLab** — auto-detects provider from git remote
- **Dual-pane diff viewer** — sidebar file tree + unified diff with inline comments
- **Threaded discussions** — view, reply, edit, delete, and resolve/unresolve comment threads
- **Note selection** — cycle through notes in a thread with `<Tab>`/`<S-Tab>`, then edit or delete inline
- **AI-powered review** — Claude-based code review with accept/dismiss/edit suggestions
- **Review sessions** — accumulate draft comments, submit in batch
- **MR actions** — approve, merge, open in browser, create new MR/PR
- **Picker integration** — Telescope, FZF, or Snacks
- **Fully remappable keybindings** — override or disable any binding

## Installation

### lazy.nvim

```lua
{
  "afewyards/codereview.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  cmd = { "CodeReview" },
  opts = {},
}
```

### packer.nvim

```lua
use {
  "afewyards/codereview.nvim",
  requires = { "nvim-lua/plenary.nvim" },
  config = function()
    require("codereview").setup()
  end,
}
```

## Quick Start

```vim
:CodeReview
```

Opens a picker with open PRs/MRs. Select one to enter the review view with a file sidebar and diff viewer.

## Project Configuration

Create a `.codereview.nvim` file in your project root to set per-project defaults:

```ini
# codereview.nvim project config
platform = github
project = afewyards/codereview.nvim
base_url = https://api.github.com
token = ghp_xxxxxxxxxxxx
```

Lines starting with `#` are comments. Keys and values are trimmed of whitespace.

| Key | Description |
|-----|-------------|
| `platform` | `github` or `gitlab` (auto-detected from git remote if omitted) |
| `project` | `owner/repo` (auto-detected from git remote if omitted) |
| `base_url` | API URL override (e.g., self-hosted GitLab instance) |
| `token` | Auth token for this project |

> **Security:** Add `.codereview.nvim` to your `.gitignore` if it contains a token.

## Authentication

Token resolution order (first match wins):

1. Environment variable — `GITHUB_TOKEN` or `GITLAB_TOKEN`
2. Project config — `token` key in `.codereview.nvim`
3. Plugin setup — `token` option in `setup()`

## Plugin Configuration

```lua
require("codereview").setup({
  -- Provider settings (all auto-detected from git remote)
  base_url = nil,       -- API base URL override
  project  = nil,       -- "owner/repo" override
  platform = nil,       -- "github" | "gitlab" | nil (auto-detect)
  token    = nil,       -- auth token (falls back to env vars)

  -- Picker: "telescope", "fzf", or "snacks" (auto-detected)
  picker = nil,

  -- Diff viewer
  diff = {
    context          = 8,   -- lines of context (0-20)
    scroll_threshold = 50,  -- use scroll mode when file count <= threshold
  },

  -- AI review (requires Claude CLI)
  ai = {
    enabled   = true,
    claude_cmd = "claude",
    agent      = "code-review",
  },

  -- Override or disable keybindings
  keymaps = {
    -- quit = "q",          -- remap quit to q
    -- toggle_resolve = false,  -- disable toggle resolve
  },
})
```

## Default Keymaps

### Navigation

| Key | Action |
|-----|--------|
| `]f` / `[f` | Next / previous file |
| `]c` / `[c` | Next / previous comment |
| `]s` / `[s` | Next / previous AI suggestion |

### Comments & Discussions

| Key | Action |
|-----|--------|
| `cc` | New comment (normal mode) |
| `cc` | Range comment (visual mode) |
| `r` | Reply to thread |
| `gt` | Toggle resolve / unresolve |

### Comments & Notes

| Key | Action |
|-----|--------|
| `<Tab>` / `<S-Tab>` | Select next / previous note |
| `e` | Edit selected note |
| `x` | Delete selected note |

### AI Suggestions

| Key | Action |
|-----|--------|
| `A` | Start / cancel AI review |
| `a` | Accept suggestion |
| `x` | Dismiss suggestion |
| `e` | Edit suggestion |
| `ds` | Dismiss all suggestions |

### View Controls

| Key | Action |
|-----|--------|
| `+` / `-` | Increase / decrease context lines |
| `<C-f>` | Toggle full file view |
| `<C-a>` | Toggle scroll / per-file mode |

### Actions

| Key | Action |
|-----|--------|
| `S` | Submit draft comments |
| `a` | Approve MR/PR |
| `m` | Merge |
| `o` | Open in browser |
| `p` | Show pipeline status |
| `R` | Refresh |
| `Q` | Quit |

All keymaps can be remapped or disabled via the `keymaps` option in `setup()`.

## Commands

| Command | Description |
|---------|-------------|
| `:CodeReview` | Open review picker |
| `:CodeReviewAI` | Run AI review on current diff |
| `:CodeReviewStart` | Start manual review session (comments become drafts) |
| `:CodeReviewSubmit` | Submit draft comments |
| `:CodeReviewApprove` | Approve current MR/PR |
| `:CodeReviewOpen` | Create new MR/PR |

## Supported Providers

| Provider | Reviews | Comments | Resolve | AI Review | Create MR/PR |
|----------|---------|----------|---------|-----------|-------------|
| GitLab | Yes | Yes | Yes | Yes | Yes |
| GitHub | Yes | Yes | Yes | Yes | Yes |

Provider is auto-detected from the git remote URL. Use `platform = "github"` or `platform = "gitlab"` to override.

## License

MIT
