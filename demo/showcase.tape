# codereview.nvim — Full Showcase
# Run: vhs demo/showcase.tape

Require nvim

Output demo/showcase.gif
Output demo/showcase.mp4

Set Shell "bash"
Set FontSize 16
Set Theme { "name": "Gruvbox Material", "black": "#32302f", "red": "#ea6962", "green": "#a9b665", "yellow": "#d8a657", "blue": "#7daea3", "magenta": "#d3869b", "cyan": "#89b482", "white": "#d4be98", "brightBlack": "#7c6f64", "brightRed": "#ea6962", "brightGreen": "#a9b665", "brightYellow": "#d8a657", "brightBlue": "#7daea3", "brightMagenta": "#d3869b", "brightCyan": "#89b482", "brightWhite": "#ddc7a1", "background": "#32302f", "foreground": "#d4be98", "selection": "#504945", "cursor": "#d4be98" }
Set Width 1400
Set Height 800
Set Padding 20
Set WindowBar Colorful
Set TypingSpeed 50ms

# Bootstrap deps (hidden)
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

# Select first PR (Refactor auth middleware)
Enter
Wait+Screen /auth\.ts/
Sleep 2s

# Navigate to next file
Type "]f"
Sleep 1500ms

# Navigate to next file
Type "]f"
Sleep 1500ms

# Go back to first file
Type "[f"
Sleep 1500ms
Type "[f"
Sleep 1500ms

# Create a comment on a line
Type "jjjjj"
Sleep 500ms
Type "cc"
Sleep 1s
Type "Consider using a constant for the error message string"
Sleep 1s
Escape
Sleep 1500ms

# Tab to navigate to existing comment
Tab
Sleep 1s
Tab
Sleep 1s

# Reply to existing discussion
Type "r"
Sleep 1s
Type "Agreed, this is cleaner now"
Sleep 800ms
Escape
Sleep 1500ms

# Quit
Type "Q"
Sleep 1s

# Exit nvim
Type ":qa!"
Enter
Sleep 500ms
