# codereview.nvim — AI Review Demo
# Run: vhs demo/ai-review.tape

Require nvim

Output demo/ai-review.gif
Output demo/ai-review.mp4

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
Show

# Open Neovim
Type "./demo/run-nvim"
Enter
Sleep 2s

# Open CodeReview picker
Type ":CodeReview"
Enter
Wait+Screen /Refactor auth/
Sleep 1s

# Select PR #42 — Refactor auth middleware
Enter
Wait+Screen /auth\.ts/
Sleep 2s

# Trigger AI review (A = ai_review keymap)
Type "A"

# Wait for mock-claude to complete (3s sleep + render time)
Sleep 5s

# Navigate to first suggestion (error: module-level throw in token.ts)
Tab
Sleep 800ms

# Accept — posts as a draft comment
Type "a"
Sleep 1s

# Navigate to next suggestion (warning: case-insensitive Bearer check)
Tab
Sleep 800ms

# Edit the suggestion text before accepting:
# 'e' opens the popup in normal mode with the prefill;
# 'GA' jumps to the last line and enters insert mode at end of line.
Type "e"
Sleep 800ms
Type "GA"
Type " — update extractTokenFromHeader to use toLowerCase()."
Ctrl+Enter
Sleep 1s

# Navigate to next suggestion (suggestion: clock tolerance)
Tab
Sleep 800ms

# Dismiss this one
Type "x"
Sleep 800ms

# Dismiss all remaining suggestions (info: more test cases)
Type "ds"
Sleep 800ms

# Open submit float — type a review body and publish
Type "S"
Sleep 1s
Type "Security issues addressed. Bearer check and password hashing need follow-up."
Sleep 800ms
Ctrl+Enter
Sleep 1s

# Quit the diff view
Type "Q"
Sleep 500ms

# Exit Neovim
Type ":qa!"
Enter
Sleep 500ms
