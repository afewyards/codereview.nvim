```text
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

**Review merge requests and pull requests from your editor. Supports GitLab and GitHub.**

## Features

- Browse open MRs/PRs via fuzzy finder (Telescope, fzf-lua, or snacks.nvim)
- View diffs with syntax highlighting and inline discussion threads
- Post comments, range comments, and replies on specific lines
- Resolve discussions (GitLab)
- Approve, merge, and close reviews
- AI-assisted code review via Claude CLI
- Auto-detects platform and project from git remote

## Requirements

- Neovim >= 0.10
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- A picker: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim), [fzf-lua](https://github.com/ibhagwan/fzf-lua), or [snacks.nvim](https://github.com/folke/snacks.nvim)
- A GitHub or GitLab personal access token

## Installation

**lazy.nvim**

```lua
{
  "afewyards/codereview.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {},
}
```

**packer.nvim**

```lua
use {
  "afewyards/codereview.nvim",
  requires = { "nvim-lua/plenary.nvim" },
  config = function()
    require("codereview").setup()
  end,
}
```

## Configuration

```lua
require("codereview").setup()
```

Full options with defaults:

```lua
require("codereview").setup({
  base_url = nil,           -- auto-detected from git remote
  project = nil,            -- auto-detected (owner/repo)
  platform = nil,           -- "github" | "gitlab" (auto-detected)
  token = nil,              -- from GITHUB_TOKEN or GITLAB_TOKEN env var
  picker = nil,             -- "telescope" | "fzf" | "snacks" (auto-detected)
  diff = {
    context = 8,            -- lines of context around changes
    scroll_threshold = 50,  -- file count threshold for scroll mode
  },
  ai = {
    enabled = true,         -- enable AI review features
    claude_cmd = "claude",  -- Claude CLI command
  },
})
```

## Authentication

Token resolution order:

1. `GITHUB_TOKEN` / `GITLAB_TOKEN` environment variable
2. `.codereview.json` in project root
3. `token` field in `setup()` config

## Commands

| Command | Description |
|---------|-------------|
| `:CodeReview` | Open MR/PR picker |
| `:CodeReviewApprove` | Approve current review |
| `:CodeReviewAI` | Run AI review |
| `:CodeReviewSubmit` | Submit draft comments |

## Keybindings

### MR Detail View

| Key | Action |
|-----|--------|
| `q` | Close |
| `o` | Open in browser |
| `R` | Refresh |
| `m` | Merge / close |
| `c` | Post comment |

### Diff View

| Key | Action |
|-----|--------|
| `c` | Comment on line |
| `C` | Range comment |
| `o` | View thread |
| `r` | Reply |
| `R` | Toggle resolve (GitLab) |

## License

MIT
