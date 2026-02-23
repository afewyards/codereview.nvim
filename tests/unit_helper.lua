package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

-- Create minimal vim global for testing
_G.vim = {
  fn = {
    tempname = function() return "/tmp/test_" .. math.random(10000) end,
    delete = function() return 0 end,
    mkdir = function() return 0 end,
    isdirectory = function() return 0 end,
    filereadable = function() return 0 end,
    writefile = function() return 0 end,
    readfile = function() return {} end,
    fnamemodify = function(fname, mod)
      if mod == ":t" then
        return fname:match("([^/]+)$") or fname
      end
      return fname
    end,
    systemlist = function() return {} end,
    split = function(s, sep)
      local result = {}
      for part in (s .. sep):gmatch("(.-)(" .. sep .. ")") do
        table.insert(result, part)
      end
      return result
    end,
    sign_define = function() return 1 end,
    timer_start = function() return 1 end,
    timer_stop = function() end,
  },
  api = {
    nvim_command = function() end,
    nvim_create_augroup = function() return 1 end,
    nvim_create_autocmd = function() return 1 end,
    nvim_buf_set_keymap = function() end,
    nvim_set_keymap = function() end,
    nvim_open_win = function() return 1 end,
    nvim_buf_get_lines = function() return {} end,
    nvim_buf_set_lines = function() end,
    nvim_win_get_cursor = function() return { 1, 0 } end,
    nvim_win_set_cursor = function() end,
    nvim_create_buf = function() return 1 end,
    nvim_create_namespace = function() return 1 end,
    nvim_set_hl = function() end,
    nvim_get_hl = function() return { bold = true } end,
    nvim_buf_clear_namespace = function() end,
    nvim_buf_add_highlight = function() end,
    nvim_buf_set_extmark = function() return 1 end,
    nvim_buf_call = function(buf, fn) return fn() end,
    nvim_buf_delete = function() end,
    nvim_get_current_win = function() return 1 end,
    nvim_win_is_valid = function() return true end,
    nvim_win_set_buf = function() end,
    nvim_set_option_value = function() end,
    nvim_buf_is_valid = function() return true end,
    nvim_win_close = function() end,
    nvim_buf_line_count = function() return 0 end,
    nvim_buf_get_extmarks = function() return {} end,
  },
  b = {
    foo = {}
  },
  wo = setmetatable({}, {
    __index = function(t, k)
      if type(k) == "number" then
        return setmetatable({}, {
          __index = function() return false end,
          __newindex = function() end,
        })
      end
      return ""
    end,
    __newindex = function() end,
  }),
  bo = setmetatable({}, {
    __index = function(t, k)
      if type(k) == "number" then
        return setmetatable({}, {
          __index = function() return "diff" end,
          __newindex = function() end,
        })
      end
      if k == "filetype" then return "diff" end
      return {}
    end,
    __newindex = function() end,
  }),
  o = setmetatable({}, {
    __index = function() return "" end,
    __newindex = function() end,
  }),
  v = {
    shell_error = 0,
  },
  env = {},
  log = {
    levels = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5 }
  },
  notify = function() end,
  schedule = function(fn) fn() end,
  cmd = function() end,
  split = function(s, sep, opts)
    local result = {}
    if not s or s == "" then return result end
    for part in (s .. sep):gmatch("(.-)(" .. sep .. ")") do
      table.insert(result, part)
    end
    return result
  end,
  filetype = {
    match = function() return nil end,
  },
  deepcopy = function(t)
    local copy = {}
    for k, v in pairs(t) do
      if type(v) == "table" then
        copy[k] = vim.deepcopy(v)
      else
        copy[k] = v
      end
    end
    return copy
  end,
  tbl_extend = function(behavior, ...)
    local result = {}
    for _, tbl in ipairs({...}) do
      for k, v in pairs(tbl) do
        result[k] = v
      end
    end
    return result
  end,
  trim = function(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
  end,
  json = {
    encode = function(t)
      -- Simple JSON encoder for testing
      if t == vim.NIL or t == nil then return "null" end
      if type(t) == "boolean" then return tostring(t) end
      if type(t) == "number" then return tostring(t) end
      if type(t) == "string" then return '"' .. t:gsub('"', '\\"') .. '"' end
      if type(t) == "table" then
        local items = {}
        for k, v in pairs(t) do
          table.insert(items, '"' .. k .. '":' .. vim.json.encode(v))
        end
        return "{" .. table.concat(items, ",") .. "}"
      end
      return "null"
    end,
    decode = function(s)
      -- Simple JSON decoder for testing
      return s
    end,
  },
  NIL = setmetatable({}, {
    __tostring = function() return "vim.NIL" end
  }),
}

-- Stub plenary.curl to avoid LuaRocks dependency
package.preload["plenary.curl"] = function()
  return {
    get = function() end,
    post = function() end,
    patch = function() end,
    delete = function() end,
    request = function()
      return { status = 200, body = vim.json.encode({}) }
    end,
  }
end

-- Stub plenary.async and plenary.async.util
package.preload["plenary.async"] = function()
  return {
    run = function(fn)
      fn()
    end,
  }
end

package.preload["plenary.async.util"] = function()
  return {
    scheduler = function() end,
  }
end
