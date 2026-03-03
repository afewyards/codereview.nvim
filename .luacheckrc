std = "luajit"
globals = { "vim" }
max_line_length = false
unused_args = false

files["tests/"] = {
  globals = { "describe", "it", "before_each", "after_each", "setup", "teardown", "pending", "spy", "stub", "mock", "assert", "bit32" },
}
