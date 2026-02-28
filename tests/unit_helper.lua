package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

-- Environment override infrastructure (must be before _G.vim)
local _env_overrides = {}
local _NIL_SENTINEL = {}
local _real_getenv = os.getenv

os.getenv = function(key)
  local v = _env_overrides[key]
  if v == _NIL_SENTINEL then return nil end
  if v ~= nil then return v end
  return _real_getenv(key)
end

-- Highlight store (must be before _G.vim)
local _hl_store = {}

-- Buffer content store (must be before _G.vim)
local _buf_store = {}
local _buf_counter = 0

-- Extmark store
local _extmark_store = {}
local _extmark_counter = 0

-- Namespace store
local _ns_store = {}
local _ns_counter = 0

-- Sign store
local _sign_store = {}

-- Keymap store
local _keymap_store = {}

-- Create minimal vim global for testing
_G.vim = {
  fn = {
    tempname = function() return "/tmp/test_" .. math.random(10000) end,
    delete = function(path, flags)
      if flags and flags:find("r") then
        os.execute("rm -rf '" .. path .. "'")
      else
        os.remove(path)
      end
      return 0
    end,
    mkdir = function(dir, flags)
      os.execute("mkdir -p '" .. dir .. "'")
      return 0
    end,
    isdirectory = function() return 0 end,
    filereadable = function(path)
      local f = io.open(path, "r")
      if f then
        f:close()
        return 1
      end
      return 0
    end,
    writefile = function(lines, path)
      local f = io.open(path, "w")
      if f then
        f:write(table.concat(lines, "\n"))
        f:close()
      end
      return 0
    end,
    readfile = function(path)
      local f = io.open(path, "r")
      if not f then return {} end
      local content = f:read("*a")
      f:close()
      local lines = {}
      for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        table.insert(lines, line)
      end
      -- Remove trailing empty line added by the gmatch trick if content ends with \n
      if #lines > 0 and lines[#lines] == "" and content:sub(-1) == "\n" then
        table.remove(lines)
      end
      return lines
    end,
    shellescape = function(s)
      return "'" .. s:gsub("'", "'\\''") .. "'"
    end,
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
    sign_define = function(name, opts)
      _sign_store[name] = vim.tbl_extend("force", { name = name }, opts or {})
      return 1
    end,
    sign_getdefined = function(name)
      if name then
        local s = _sign_store[name]
        return s and { s } or {}
      end
      local result = {}
      for _, s in pairs(_sign_store) do
        table.insert(result, s)
      end
      return result
    end,
    sign_place = function() return 1 end,
    sign_unplace = function() return 0 end,
    timer_start = function() return 1 end,
    timer_stop = function() end,
    getreg = function() return "" end,
    confirm = function() return 1 end,
    strdisplaywidth = function(s)
      local w = 0
      local i = 1
      local len = #s
      while i <= len do
        local b = s:byte(i)
        if b < 0x80 then
          w = w + 1; i = i + 1
        elseif b < 0xE0 then
          w = w + 1; i = i + 2
        elseif b < 0xF0 then
          w = w + 1; i = i + 3
        else
          -- 4-byte sequences (emoji) are typically 2 display columns
          w = w + 2; i = i + 4
        end
      end
      return w
    end,
    screenpos = function() return { row = 5, col = 1 } end,
    getwininfo = function() return {{ topline = 1 }} end,
    winrestview = function() end,
    winsaveview = function() return { lnum = 1, topline = 1 } end,
  },
  api = {
    nvim_command = function() end,
    nvim_create_augroup = function() return 1 end,
    nvim_create_autocmd = function() return 1 end,
    nvim_buf_set_keymap = function() end,
    nvim_set_keymap = function() end,
    nvim_open_win = function() return 1 end,
    nvim_buf_get_lines = function(buf, start, end_, strict)
      local store = _buf_store[buf] or {}
      local real_end = end_ >= 0 and end_ or #store
      local result = {}
      for i = start + 1, real_end do
        table.insert(result, store[i] or "")
      end
      return result
    end,
    nvim_buf_set_lines = function(buf, start, end_, strict, lines)
      if not _buf_store[buf] then _buf_store[buf] = {} end
      local store = _buf_store[buf]
      local real_end = end_ >= 0 and end_ or #store
      local new = {}
      -- Lines before replaced range (1-indexed: 1..start since API is 0-indexed)
      for i = 1, start do
        table.insert(new, store[i])
      end
      -- Replacement lines
      for _, l in ipairs(lines) do
        table.insert(new, l)
      end
      -- Lines after replaced range
      for i = real_end + 1, #store do
        table.insert(new, store[i])
      end
      _buf_store[buf] = new
    end,
    nvim_win_get_cursor = function() return { 1, 0 } end,
    nvim_win_get_width = function() return 120 end,
    nvim_win_set_width = function() end,
    nvim_win_set_cursor = function() end,
    nvim_create_buf = function(listed, scratch)
      _buf_counter = _buf_counter + 1
      _buf_store[_buf_counter] = {}
      return _buf_counter
    end,
    nvim_create_namespace = function(name)
      if name and _ns_store[name] then return _ns_store[name] end
      _ns_counter = _ns_counter + 1
      if name then _ns_store[name] = _ns_counter end
      return _ns_counter
    end,
    nvim_set_hl = function(ns, name, opts) _hl_store[name] = opts end,
    nvim_get_hl = function(ns, opts) return _hl_store[opts.name] or {} end,
    nvim_buf_clear_namespace = function(buf, ns, start, end_)
      if _extmark_store[buf] then _extmark_store[buf][ns] = nil end
    end,
    nvim_buf_add_highlight = function() end,
    nvim_buf_set_extmark = function(buf, ns, row, col, opts)
      _extmark_counter = _extmark_counter + 1
      if not _extmark_store[buf] then _extmark_store[buf] = {} end
      if not _extmark_store[buf][ns] then _extmark_store[buf][ns] = {} end
      table.insert(_extmark_store[buf][ns], { _extmark_counter, row, col, opts or {} })
      return _extmark_counter
    end,
    nvim_buf_call = function(buf, fn) return fn() end,
    nvim_buf_delete = function(buf, opts)
      _buf_store[buf] = nil
      _extmark_store[buf] = nil
    end,
    nvim_get_current_win = function() return 1 end,
    nvim_set_current_win = function() end,
    nvim_win_is_valid = function() return true end,
    nvim_win_set_buf = function() end,
    nvim_set_option_value = function() end,
    nvim_buf_is_valid = function() return true end,
    nvim_win_close = function() end,
    nvim_buf_line_count = function(buf)
      return #(_buf_store[buf] or {})
    end,
    nvim_buf_attach = function(buf, send_buffer, callbacks) return true end,
    nvim_win_get_height = function() return 10 end,
    nvim_win_set_height = function() end,
    nvim_win_get_position = function() return { 0, 0 } end,
    nvim_win_call = function(win, fn) return fn() end,
    nvim_win_get_buf = function() return 1 end,
    nvim_buf_get_extmarks = function(buf, ns, start, end_, opts)
      if not _extmark_store[buf] then return {} end
      -- Parse start/end row bounds (supports both number and {row, col} tuple)
      local start_row = type(start) == "table" and start[1] or 0
      local end_row = type(end_) == "table" and end_[1] or (end_ == -1 and math.huge or end_)
      local function in_range(m) return m[2] >= start_row and m[2] <= end_row end
      if ns == -1 then
        -- All namespaces
        local result = {}
        for _, marks in pairs(_extmark_store[buf]) do
          for _, m in ipairs(marks) do
            if in_range(m) then table.insert(result, m) end
          end
        end
        return result
      end
      if not _extmark_store[buf][ns] then return {} end
      local result = {}
      for _, m in ipairs(_extmark_store[buf][ns]) do
        if in_range(m) then table.insert(result, m) end
      end
      return result
    end,
    nvim_buf_del_extmark = function(buf, ns, id)
      if not _extmark_store[buf] or not _extmark_store[buf][ns] then return false end
      for i, mark in ipairs(_extmark_store[buf][ns]) do
        if mark[1] == id then
          table.remove(_extmark_store[buf][ns], i)
          return true
        end
      end
      return false
    end,
    nvim_buf_get_keymap = function(buf, mode)
      if not _keymap_store[buf] then return {} end
      local result = {}
      for _, km in ipairs(_keymap_store[buf]) do
        if km.mode == mode then
          table.insert(result, km)
        end
      end
      return result
    end,
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
  o = setmetatable({ lines = 10, columns = 80 }, {
    __index = function() return "" end,
    __newindex = function() end,
  }),
  v = {
    shell_error = 0,
  },
  env = setmetatable({}, {
    __newindex = function(_, k, v)
      _env_overrides[k] = v == nil and _NIL_SENTINEL or v
    end,
    __index = function(_, k)
      local v = _env_overrides[k]
      if v == _NIL_SENTINEL then return nil end
      if v ~= nil then return v end
      return _real_getenv(k)
    end,
  }),
  log = {
    levels = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5 }
  },
  notify = function() end,
  schedule = function(fn) fn() end,
  defer_fn = function(fn, ms) fn() end,
  wait = function(ms, condition) if condition then return condition() end end,
  cmd = function() end,
  split = function(s, sep, opts)
    local result = {}
    if not s or s == "" then return result end
    for part in (s .. sep):gmatch("(.-)(" .. sep .. ")") do
      table.insert(result, part)
    end
    return result
  end,
  keymap = {
    set = function(mode, lhs, fn, opts)
      opts = opts or {}
      local buf = opts.buffer
      if buf then
        if not _keymap_store[buf] then _keymap_store[buf] = {} end
        table.insert(_keymap_store[buf], {
          mode = mode,
          lhs = lhs,
          rhs = fn,
        })
      end
    end,
  },
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
  list_extend = function(dst, src, start, finish)
    start = start or 1
    finish = finish or (src and #src or 0)
    for i = start, finish do
      table.insert(dst, src[i])
    end
    return dst
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
      if not s or type(s) ~= "string" then error("invalid json input") end
      local pos = 1
      local function skip_ws()
        local _, next_pos = s:find("^%s*", pos)
        pos = next_pos and next_pos + 1 or pos
      end
      local function char() return s:sub(pos, pos) end
      local function parse_string()
        pos = pos + 1 -- skip opening "
        local chunks = {}
        while pos <= #s do
          local c = s:sub(pos, pos)
          if c == '\\' then
            local nc = s:sub(pos + 1, pos + 1)
            if nc == 'n' then table.insert(chunks, '\n')
            elseif nc == 't' then table.insert(chunks, '\t')
            elseif nc == '"' then table.insert(chunks, '"')
            elseif nc == '\\' then table.insert(chunks, '\\')
            elseif nc == '/' then table.insert(chunks, '/')
            else table.insert(chunks, nc) end
            pos = pos + 2
          elseif c == '"' then
            pos = pos + 1
            return table.concat(chunks)
          else
            table.insert(chunks, c)
            pos = pos + 1
          end
        end
        error("unterminated string")
      end
      local function parse_number()
        local num_str = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        if not num_str then error("expected number at pos " .. pos) end
        pos = pos + #num_str
        return tonumber(num_str)
      end
      local parse_value -- forward declare
      local function parse_object()
        pos = pos + 1 -- skip {
        skip_ws()
        local obj = {}
        if char() == '}' then pos = pos + 1; return obj end
        while true do
          skip_ws()
          if char() ~= '"' then error("expected string key") end
          local key = parse_string()
          skip_ws()
          if char() ~= ':' then error("expected :") end
          pos = pos + 1
          skip_ws()
          obj[key] = parse_value()
          skip_ws()
          if char() == '}' then pos = pos + 1; return obj end
          if char() ~= ',' then error("expected , or }") end
          pos = pos + 1
        end
      end
      local function parse_array()
        pos = pos + 1 -- skip [
        skip_ws()
        local arr = {}
        if char() == ']' then pos = pos + 1; return arr end
        while true do
          skip_ws()
          table.insert(arr, parse_value())
          skip_ws()
          if char() == ']' then pos = pos + 1; return arr end
          if char() ~= ',' then error("expected , or ]") end
          pos = pos + 1
        end
      end
      parse_value = function()
        skip_ws()
        local c = char()
        if c == '"' then return parse_string()
        elseif c == '{' then return parse_object()
        elseif c == '[' then return parse_array()
        elseif c == 't' then pos = pos + 4; return true
        elseif c == 'f' then pos = pos + 5; return false
        elseif c == 'n' then pos = pos + 4; return nil
        elseif c:match("[%-%d]") then return parse_number()
        else error("unexpected character: " .. c .. " at pos " .. pos)
        end
      end
      local result = parse_value()
      return result
    end,
  },
  NIL = setmetatable({}, {
    __tostring = function() return "vim.NIL" end
  }),
  base64 = (function()
    local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local function encode(data)
      local result = {}
      local padding = 2 - ((#data - 1) % 3)
      data = data .. string.rep("\0", padding)
      for i = 1, #data, 3 do
        local a, b, c = data:byte(i), data:byte(i + 1), data:byte(i + 2)
        local idx1, idx2, idx3, idx4
        if bit32 then
          idx1 = bit32.rshift(a, 2)
          idx2 = bit32.band(a, 3) * 16 + bit32.rshift(b, 4)
          idx3 = bit32.band(b, 15) * 4 + bit32.rshift(c, 6)
          idx4 = bit32.band(c, 63)
        else
          idx1 = math.floor(a / 4)
          idx2 = (a % 4) * 16 + math.floor(b / 16)
          idx3 = (b % 16) * 4 + math.floor(c / 64)
          idx4 = c % 64
        end
        table.insert(result, b64chars:sub(idx1 + 1, idx1 + 1))
        table.insert(result, b64chars:sub(idx2 + 1, idx2 + 1))
        table.insert(result, b64chars:sub(idx3 + 1, idx3 + 1))
        table.insert(result, b64chars:sub(idx4 + 1, idx4 + 1))
      end
      local encoded = table.concat(result)
      return encoded:sub(1, #encoded - padding) .. string.rep("=", padding)
    end
    local function decode(data)
      data = data:gsub("[^" .. b64chars .. "=]", "")
      local result = {}
      local padding = data:match("=*$")
      local pad_len = padding and #padding or 0
      data = data:gsub("=", "A")
      for i = 1, #data, 4 do
        local a = b64chars:find(data:sub(i, i), 1, true) - 1
        local b = b64chars:find(data:sub(i + 1, i + 1), 1, true) - 1
        local c = b64chars:find(data:sub(i + 2, i + 2), 1, true) - 1
        local d = b64chars:find(data:sub(i + 3, i + 3), 1, true) - 1
        local v = bit32 and (bit32.lshift(a, 18) + bit32.lshift(b, 12) + bit32.lshift(c, 6) + d)
               or (a * 2^18 + b * 2^12 + c * 2^6 + d)
        local b1 = bit32 and bit32.rshift(bit32.band(v, 0xFF0000), 16) or (math.floor(v / 2^16) % 256)
        local b2 = bit32 and bit32.rshift(bit32.band(v, 0x00FF00), 8) or (math.floor(v / 2^8) % 256)
        local b3 = bit32 and bit32.band(v, 0x0000FF) or (v % 256)
        table.insert(result, string.char(b1, b2, b3))
      end
      local decoded = table.concat(result)
      return decoded:sub(1, #decoded - pad_len)
    end
    return { encode = encode, decode = decode }
  end)(),
}

-- Stub plenary.curl to avoid LuaRocks dependency
local _plenary_curl_stub = {
  get = function() end,
  post = function() end,
  patch = function() end,
  delete = function() end,
  request = function()
    return { status = 200, body = vim.json.encode({}) }
  end,
}

package.preload["plenary.curl"] = function()
  return _plenary_curl_stub
end

-- Expose for test overrides
_G._plenary_curl_stub = _plenary_curl_stub

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
