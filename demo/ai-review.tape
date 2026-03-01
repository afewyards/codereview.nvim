# codereview.nvim — AI Review Demo
# Run: vhs demo/ai-review.tape

Require nvim

Output demo/ai-review.gif

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

# Open CodeReview picker
Type ":CodeReview"
Enter
Wait+Screen /Refactor auth/
Sleep 1s

# Select PR #42 — Refactor auth middleware
Enter
Wait+Screen /auth\.ts/
Sleep 2s

# ── Browse existing discussions in summary view ────────────
# Tab cycles through discussion thread headers in summary mode
Tab
Sleep 800ms
Tab
Sleep 800ms

# ── While AI loads: reply to existing discussion ───────────
# Tab to Charlie's unresolved comment on token.ts (disc-002)
Tab
Sleep 1500ms
# ── Now in diff view — trigger AI review ───────────────────
Type "A"

# Reply to the thread
Type "r"
Sleep 500ms
Type "Good idea — I'll open a follow-up issue for multi-scheme support."
Ctrl+S
Sleep 1s

# ── Wait for AI suggestions to finish appearing ───────────
# auth.ts completes at ~2s, token.ts ~3s, login.ts ~4s, auth.test.ts ~5s
Sleep 3s

Shift+Tab
Sleep 800ms

# Accept — posts as a draft comment
Type "a"
Sleep 1s

# Navigate to next suggestion (warning: case-insensitive Bearer check)
Tab
Sleep 800ms
Tab
Sleep 800ms
Tab
Sleep 800ms

# Edit the suggestion text before accepting:
# 'e' opens the popup in normal mode with the prefill;
# 'GA' jumps to the last line and enters insert mode at end of line.
Type "e"
Sleep 800ms
Type "GA"
Type " — update extractTokenFromHeader to use toLowerCase()."
Ctrl+S
Sleep 2s

# Navigate to next suggestion (suggestion: clock tolerance)
Tab
Sleep 800ms

# Dismiss this one
Type "a"
Sleep 800ms

# Dismiss all remaining suggestions (info: more test cases)
Type "ds"
Sleep 1800ms

# ── Submit review ──────────────────────────────────────────
# Open submit float — should show AI-generated summary as prefill
Type "S"
Sleep 1s
# Clear the prefill and type custom review body
Type "ggVGd"
Sleep 300ms
Type "i"
Type "Security issues addressed. Bearer check and password hashing need follow-up."
Escape
Sleep 800ms
Tab
Sleep 800ms
Tab
Sleep 800ms
Ctrl+S
Sleep 4s

