package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

-- Stub plenary.curl to avoid LuaRocks dependency
package.preload["plenary.curl"] = function()
  return {
    get = function() end,
    post = function() end,
    patch = function() end,
    delete = function() end,
  }
end

-- Stub plenary.async and plenary.async.util
package.preload["plenary.async"] = function()
  return {
    run = function() end,
  }
end

package.preload["plenary.async.util"] = function()
  return {
    scheduler = function() end,
  }
end
