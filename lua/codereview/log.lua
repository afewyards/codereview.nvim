local M = {}

local config_mod = require("codereview.config")

local LEVELS = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
local NAMES = { "DEBUG", "INFO", "WARN", "ERROR" }
local MAX_LOG_SIZE = 1024 * 1024  -- 1 MB

local function enabled()
  local c = config_mod.get()
  return c.debug == true
end

local function log_path()
  local git = require("codereview.git")
  local root = git.get_repo_root()
  if root then return root .. "/.codereview.log" end
  return vim.fn.stdpath("cache") .. "/codereview.log"
end

local function rotate_if_needed(path)
  local stat = vim.loop.fs_stat(path)
  if stat and stat.size > MAX_LOG_SIZE then
    local rotated = path .. ".1"
    os.remove(rotated)
    os.rename(path, rotated)
  end
end

local function write(level, msg)
  if not enabled() then return end
  local path = log_path()
  rotate_if_needed(path)
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  local line = string.format("[%s] %s  %s\n", ts, NAMES[level] or "?", msg)
  local f = io.open(path, "a")
  if f then
    f:write(line)
    f:close()
  end
end

function M.debug(msg) write(LEVELS.DEBUG, msg) end
function M.info(msg) write(LEVELS.INFO, msg) end
function M.warn(msg) write(LEVELS.WARN, msg) end
function M.error(msg) write(LEVELS.ERROR, msg) end

function M.path() return log_path() end

return M
