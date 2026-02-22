# README Design

## Style
Minimal & clean, feature-list-first. Audience: Neovim users.

## Sections

### 1. Header
Block-letter ASCII art "CODE REVIEW" (Unicode box-drawing style, matching ha-adaptive-climate).
Subtitle: "Review merge requests and pull requests from your editor. Supports GitLab and GitHub."

### 2. Features
Bullet list: MR browsing (pickers), diffs + inline threads, comments/range comments/replies, resolve (GitLab), approve/merge/close, AI review via Claude, auto-detection.

### 3. Requirements
Neovim >= 0.10, plenary.nvim, picker (telescope/fzf-lua/snacks), GitHub or GitLab PAT.

### 4. Installation
lazy.nvim and packer examples.

### 5. Configuration
Minimal `setup()` call, then full options table with defaults.

### 6. Authentication
Token resolution order: env var → .codereview.json → setup() config.

### 7. Commands
Table: `:CodeReview`, `:CodeReviewApprove`, `:CodeReviewAI`, `:CodeReviewSubmit`.

### 8. Keybindings
Two tables: MR detail view keys, diff view keys.

### 9. License
MIT.
