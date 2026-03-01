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

![AI Review Demo](https://github.com/afewyards/codereview.nvim/releases/latest/download/ai-review.gif)

> **Note: This project is in active development.** Core features are operational, but some areas are still being refined. Please report issues or unexpected behavior via [GitHub Issues](https://github.com/afewyards/codereview.nvim/issues).

## Features

- **GitHub + GitLab** — auto-detects provider from git remote
- **Dual-pane diff viewer** — sidebar file tree + unified diff with inline comments
- **Threaded discussions** — view, reply, edit, delete, and resolve/unresolve comment threads
- **Note selection** — cycle through notes in a thread with `<Tab>`/`<S-Tab>`, then edit or delete inline
- **AI-powered review** — multi-provider support (Claude CLI, Anthropic API, OpenAI, Ollama, custom) with accept/dismiss/edit suggestions
- **Review sessions** — accumulate draft comments, submit in batch
- **MR actions** — approve, merge, open in browser, create new MR/PR

![Create MR/PR](https://github.com/afewyards/codereview.nvim/releases/latest/download/open-mr.gif)

- **Pipeline view** — monitor CI/CD status, view job logs, retry failed jobs

![Pipeline View](https://github.com/afewyards/codereview.nvim/releases/latest/download/pipeline.gif)

- **Picker integration** — Telescope, FZF, or Snacks
- **Fully remappable keybindings** — override or disable any binding

## Installation

### lazy.nvim

```lua
{
  "afewyards/codereview.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  cmd = {
    "CodeReview",
    "CodeReviewAI",
    "CodeReviewAIFile",
    "CodeReviewStart",
    "CodeReviewSubmit",
    "CodeReviewApprove",
    "CodeReviewOpen",
    "CodeReviewPipeline",
    "CodeReviewComments",
    "CodeReviewFiles",
  },
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
3. Plugin setup — `github_token` or `gitlab_token` in `setup()`

## Plugin Configuration

```lua
require("codereview").setup({
  -- Provider settings (all auto-detected from git remote)
  base_url = nil,       -- API base URL override
  project  = nil,       -- "owner/repo" override
  platform = nil,       -- "github" | "gitlab" | nil (auto-detect)
  github_token = nil,   -- GitHub personal access token
  gitlab_token = nil,   -- GitLab personal access token

  -- Picker: "telescope", "fzf", or "snacks" (auto-detected)
  picker = nil,

  -- Debug logging to .codereview.log
  debug = false,

  -- Diff viewer
  diff = {
    context          = 8,     -- lines of context (0-20)
    scroll_threshold = 50,    -- use scroll mode when file count <= threshold
    comment_width    = 80,    -- comment float width
    separator_char   = "╳",   -- hunk separator character
    separator_lines  = 3,     -- lines in hunk separator
  },

  -- AI review
  ai = {
    enabled       = true,
    provider      = "claude_cli",  -- "claude_cli" | "anthropic" | "openai" | "ollama" | "custom_cmd"
    review_level  = "info",        -- "info" | "suggestion" | "warning" | "error"
    max_file_size = 500,           -- skip files larger than N lines (0 = unlimited)

    claude_cli = { cmd = "claude", agent = "code-review" },
    anthropic  = { api_key = nil, model = "claude-sonnet-4-20250514" },
    openai     = { api_key = nil, model = "gpt-4o", base_url = nil },
    ollama     = { model = "llama3", base_url = "http://localhost:11434" },
    custom_cmd = { cmd = nil, args = {} },
  },

  -- Override or disable keybindings
  keymaps = {
    -- quit = "q",              -- remap quit to q
    -- toggle_resolve = false,  -- disable toggle resolve
  },
})
```

### AI Providers

Set `ai.provider` to choose a backend. Each provider has its own sub-table:

| Provider | Config key | Requirements |
|----------|-----------|--------------|
| Claude CLI | `claude_cli` | [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) installed |
| Anthropic API | `anthropic` | `api_key` set |
| OpenAI | `openai` | `api_key` set |
| Ollama | `ollama` | Ollama running locally |
| Custom command | `custom_cmd` | `cmd` set |

**Example — Anthropic API:**
```lua
ai = {
  provider = "anthropic",
  anthropic = { api_key = vim.env.ANTHROPIC_API_KEY, model = "claude-sonnet-4-20250514" },
},
```

**Example — Ollama (local):**
```lua
ai = {
  provider = "ollama",
  ollama = { model = "llama3", base_url = "http://localhost:11434" },
},
```

### AI Review Level

The `ai.review_level` option controls the verbosity of AI code reviews. Higher levels filter out lower-severity comments:

| Level | Shows |
|-------|-------|
| `"info"` | Everything (default) |
| `"suggestion"` | Suggestions, warnings, and errors |
| `"warning"` | Warnings and errors only |
| `"error"` | Errors only |

The AI is instructed to skip items below the configured level, saving tokens and reducing noise. To see lower-severity items again, change the level and re-run the AI review.

## Default Keymaps

### Navigation

| Key | Action |
|-----|--------|
| `]f` / `[f` | Next / previous file |
| `Tab` / `S-Tab` | Next / previous annotation (comment or AI suggestion), cycles within row then across rows and files |

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
| `af` | AI review current file |
| `a` | Accept suggestion |
| `x` | Dismiss suggestion |
| `e` | Edit suggestion |
| `ds` | Dismiss all suggestions |

### View Controls

| Key | Action |
|-----|--------|
| `<C-f>` | Toggle full file view |
| `<C-a>` | Toggle scroll / per-file mode |
| `+` / `-` | Increase / decrease context lines |

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

### Picker

| Key | Action |
|-----|--------|
| `<leader>fc` | Browse comments / suggestions |
| `<leader>ff` | Browse changed files |

### Movement

| Key | Action |
|-----|--------|
| `j` / `k` | Move down / up (comment-aware) |

### Customizing Keymaps

Every keybinding can be remapped to a different key or disabled entirely via the `keymaps` option:

```lua
keymaps = {
  quit = "q",              -- remap quit from Q to q
  toggle_resolve = false,  -- disable toggle resolve
  ai_review = "<leader>ar", -- remap AI review
},
```

Available action names: `next_file`, `prev_file`, `create_comment`, `create_range_comment`, `reply`, `toggle_resolve`, `increase_context`, `decrease_context`, `toggle_full_file`, `toggle_scroll_mode`, `accept_suggestion`, `dismiss_suggestion`, `edit_suggestion`, `dismiss_all_suggestions`, `submit`, `approve`, `open_in_browser`, `merge`, `show_pipeline`, `ai_review`, `ai_review_file`, `refresh`, `quit`, `select_next_note`, `select_prev_note`, `edit_note`, `delete_note`, `pick_comments`, `pick_files`, `move_down`, `move_up`.

## Commands

| Command | Description |
|---------|-------------|
| `:CodeReview` | Open review picker |
| `:CodeReviewAI` | Run AI review on entire diff |
| `:CodeReviewAIFile` | Run AI review on current file |
| `:CodeReviewStart` | Start manual review session (comments become drafts) |
| `:CodeReviewSubmit` | Submit draft comments |
| `:CodeReviewApprove` | Approve current MR/PR |
| `:CodeReviewOpen` | Create new MR/PR |
| `:CodeReviewPipeline` | Show pipeline status |
| `:CodeReviewComments` | Browse comments and suggestions |
| `:CodeReviewFiles` | Browse changed files |

## Supported Providers

| Provider | Reviews | Comments | Resolve | AI Review | Create MR/PR |
|----------|---------|----------|---------|-----------|-------------|
| GitLab | Yes | Yes | Yes | Yes | Yes |
| GitHub | Yes | Yes | Yes | Yes | Yes |

Provider is auto-detected from the git remote URL. Use `platform = "github"` or `platform = "gitlab"` to override.

## License

MIT
