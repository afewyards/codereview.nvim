# codereview.nvim — Open MR Demo
# Run: vhs demo/open-mr.tape

Require nvim

Output demo/open-mr.gif

Set Shell "bash"
Set FontSize 16
Set Theme { "name": "Gruvbox Material", "black": "#32302f", "red": "#ea6962", "green": "#a9b665", "yellow": "#d8a657", "blue": "#7daea3", "magenta": "#d3869b", "cyan": "#89b482", "white": "#d4be98", "brightBlack": "#7c6f64", "brightRed": "#ea6962", "brightGreen": "#a9b665", "brightYellow": "#d8a657", "brightBlue": "#7daea3", "brightMagenta": "#d3869b", "brightCyan": "#89b482", "brightWhite": "#ddc7a1", "background": "#32302f", "foreground": "#d4be98", "selection": "#504945", "cursor": "#d4be98" }
Set Width 1400
Set Height 800
Set Padding 20
Set WindowBar Colorful
Set TypingSpeed 50ms

# Bootstrap deps (hidden, first run only)
Hide
Type "nvim -u demo/init.lua --headless -c 'sleep 100m | qa'"
Enter
Sleep 10s

# Open Neovim
Type "./demo/run-nvim"
Enter
Show

# Let Neovim fully initialize (screenkey toggle at 1500ms)
Sleep 2s

# ── Open MR creation ─────────────────────────────────────
Type ":CodeReviewOpen"
Enter

# "Pushed feat/user-settings to origin" notification appears
Sleep 1500ms

# "Generating MR description..." notification + AI spinner
# mock-claude sleeps 2s then returns the title/description
Wait+Screen /Create MR/
Sleep 2s

# ── Editor float is now visible with AI-generated content ──
# Buffer contains:
#   feat: add user preferences and settings page    (title, no prefix)
#   ──────────────────────────────────────────────── (virtual separator)
#   - Add `/settings` route with preference form ... (description)
#   - New `UserPreferences` model with defaults and validation
#   - Settings persist to database via `PATCH /api/preferences`
#   - Unit tests for preference validation and API endpoint
#
# Footer: ◀ No Draft ▶  <C-t> main  <C-s> submit

# ── 1. Edit the title ────────────────────────────────────
# Cursor starts on title line, change entire line
Type "gg0C"
Sleep 300ms
Type "feat: add user settings page"
Escape
Sleep 1s

# ── 2. Toggle draft via footer ─────────────────────────
# Tab cycles draft mode in the footer (No Draft → Draft)
Tab
Sleep 1500ms

# ── 3. Add a line to description ─────────────────────────
# Jump to end of buffer, open new line
Type "Go"
Type "- Closes #127"
Escape
Sleep 1500ms

# ── 4. Submit ────────────────────────────────────────────
Ctrl+S
Sleep 3s
