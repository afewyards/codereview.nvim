# codereview.nvim — Pipeline Demo
# Run: vhs demo/pipeline.tape

Require nvim

Output demo/pipeline.gif

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

# Open CodeReview picker
Type ":CodeReview"
Enter
Wait+Screen /Refactor auth/
Sleep 1s

# Select PR #42
Enter
Wait+Screen /auth\.ts/
Sleep 2s
Show

# ── Open pipeline view ────────────────────────────────────
Type "p"
Wait+Screen /Pipeline/
Sleep 2s

# ── Navigate to test stage ────────────────────────────────
# Cursor at line 1, test stage at line 6 → 5j
Type "j"
Sleep 200ms
Type "j"
Sleep 200ms
Type "j"
Sleep 200ms
Type "j"
Sleep 200ms
Type "j"
Sleep 500ms

# Collapse the test stage
Enter
Sleep 1s

# Expand it again
Enter
Sleep 1s

# ── Open failed job log ──────────────────────────────────
# Move down to unit-tests job row (one line below test stage)
Type "j"
Sleep 500ms

# Open log view
Enter
Wait+Screen /unit-tests/
Sleep 3s

# ── Close log, back to pipeline ──────────────────────────
Type "q"
Sleep 1s

# ── Retry the failed job ─────────────────────────────────
# Cursor should be back on unit-tests row
Type "r"
Sleep 3s

