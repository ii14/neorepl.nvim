local M = {}

local parser = require('nrepl.lua.parser')
local tinsert = table.insert

local RE_IDENT = '^[%a_][%a%d_]*$'

local function match(str, re)
  local ok, res = pcall(string.match, str, re)
  return ok and res
end

--- uv.fs_scandir iterator
local function scandir_iterator(fs)
  local uv = vim.loop
  ---@return string, string
  return function()
    local dirname, dirtype = uv.fs_scandir_next(fs)
    if dirname then
      return dirname, dirtype
    end
  end
end

---@param query string
---@return string[]
local function get_modules(query)
  -- TODO: module.path, module.cpath
  -- TODO: look up module.loaded whether the 'a/b/c' style is used
  local res = {}

  local function scan(path, base, filter)
    local dir = vim.loop.fs_scandir(path)
    if not dir then return end
    for name, type in scandir_iterator(dir) do
      if filter == nil or name:sub(1, #filter) == filter then
        if type == 'file' and name:sub(-4) == ('.lua') then
          local modname = name:sub(1, -5)
          if modname == 'init' and base then
            tinsert(res, base)
          elseif modname ~= '' then
            tinsert(res, base and base..'.'..modname or modname)
          end
        elseif type == 'directory' then
          scan(path..'/'..name, base and base..'.'..name or name)
        end
      end
    end
  end

  query = vim.split(query or '', '[%./]')
  local last = table.remove(query) or ''
  local suffix = '/lua'
  local modbase
  if #query > 0 then
    suffix = suffix..'/'..table.concat(query, '/')
    modbase = table.concat(query, '.')
  end

  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    scan(path..suffix, modbase, last)
  end
  table.sort(res)
  return res
end

---@param t nreplLuaToken
---@return number
local function parse_number(t)
  return t.value:match('^%d+$') and tonumber(t.value) or nil
end

---@param t nreplLuaToken
---@return string
local function parse_string(t)
  -- TODO: interpret escape sequences
  return (not t.long and not t.incomplete) and t.value:sub(2, #t.value - 1) or nil
end

---@param es nreplLuaExp[]
---@param env table
---@return any
local function resolve(es, env)
  local var = env or _G

  for _, e in ipairs(es) do
    if e.type == 'root' then
      if type(var) ~= 'table' then return end
      local prop = var[e[1].value]
      if prop == nil then return end
      var = prop
    elseif e.type == 'prop' then
      if type(var) ~= 'table' then return end
      local prop = var[e[2].value]
      if prop == nil then return end
      var = prop
    elseif e.type == 'index' then
      if type(var) ~= 'table' then return end
      local r = (e[2].type == 'number' and parse_number or parse_string)(e[2])
      if r == nil then return end
      local prop = var[r]
      if prop == nil then return end
      var = prop
    elseif e.type == 'method' then
      return
    else
      -- call1 and call2, only for require
      if var ~= require then return end
      local r = parse_string(e.type == 'call1' and e[1] or e[2])
      if r == nil then return end
      local prop = package.loaded[r]
      if prop == nil then return end
      var = prop
    end
  end

  return var
end

local function sort_completions(a, b)
  return a.word < b.word
end

---@param var any
---@param e nreplLuaExp
---@return number, string[]
local function complete(var, e)
  -- TODO: refactor
  if var == nil or e == nil then
    return
  end

  if e.type == 'root' then
    if type(var) ~= 'table' then return end
    local res = {}
    local re = '^'..e[1].value

    for k, v in pairs(var) do
      if type(k) == 'string' and match(k, re) and k:match(RE_IDENT) then
        if type(v) == 'function' then
          local i = debug.getinfo(v, 'u')
          ---@diagnostic disable-next-line: undefined-field
          if i.isvararg or i.nparams > 0 then
            tinsert(res, {
              word = k..'(',
              abbr = k,
              menu = type(v),
            })
          else
            tinsert(res, {
              word = k..'()',
              abbr = k,
              menu = type(v),
            })
          end
        else
          tinsert(res, {
            word = k,
            abbr = k,
            menu = type(v),
          })
        end
      end
    end

    table.sort(res, sort_completions)
    return res, e[1].col
  elseif e.type == 'prop' then
    if type(var) ~= 'table' then return end
    local res = {}
    local re = '^'..(e[2] and e[2].value or '')

    for k, v in pairs(var) do
      if type(k) == 'string' and match(k, re) then
        -- TODO: escape key
        local word = k:match(RE_IDENT) and '.'..k or "['"..k.."']"
        if type(v) == 'function' then
          local i = debug.getinfo(v, 'u')
          ---@diagnostic disable-next-line: undefined-field
          if i.isvararg or i.nparams > 0 then
            tinsert(res, {
              word = word..'(',
              abbr = k,
              menu = type(v),
            })
          else
            tinsert(res, {
              word = word..'()',
              abbr = k,
              menu = type(v),
            })
          end
        else
          tinsert(res, {
            word = word,
            abbr = k,
            menu = type(v),
          })
        end
      end
    end

    table.sort(res, sort_completions)
    return res, e[1].col
  elseif e.type == 'index' then
    -- TODO
    return
  elseif e.type == 'method' then
    if type(var) ~= 'table' then return end
    local res = {}
    local re = '^'..(e[2] and e[2].value or '')

    for k, v in pairs(var) do
      if type(k) == 'string' and match(k, re) and k:match(RE_IDENT) then
        if type(v) == 'function' then
          local i = debug.getinfo(v, 'u')
          ---@diagnostic disable-next-line: undefined-field
          if i.isvararg or i.nparams > 1 then
            tinsert(res, {
              word = ':'..k..'(',
              abbr = k,
              menu = type(v),
            })
          ---@diagnostic disable-next-line: undefined-field
          elseif i.nparams > 0 then
            tinsert(res, {
              word = ':'..k..'()',
              abbr = k,
              menu = type(v),
            })
          end
        end
      end
    end

    table.sort(res, sort_completions)
    return res, e[1].col
  elseif e.type == 'call1' then
    if var ~= require then return end
    local res = {}
    if e[1].incomplete and not e[1].long then
      if e[1].long then return end
      local stype = e[1].value:sub(1,1)
      for _, modname in ipairs(get_modules(e[1].value:sub(2))) do
        -- escape string?
        tinsert(res, {
          word = stype..modname..stype,
          abbr = modname,
          menu = package.loaded[modname] ~= nil and 'module+' or 'module',
        })
      end
    end
    return res, e[1].col
  elseif e.type == 'call2' then
    if var ~= require then return end
    local res = {}
    if e[2] == nil or e[2].incomplete then
      if e[2] then
        if e[2].long then return end
        local stype = e[2].value:sub(1,1)
        for _, modname in ipairs(get_modules(e[2].value:sub(2))) do
          -- escape string?
          tinsert(res, {
            word = '('..stype..modname..stype..')',
            abbr = modname,
            menu = package.loaded[modname] ~= nil and 'module+' or 'module',
          })
        end
      else
        for _, modname in ipairs(get_modules()) do
          -- escape string?
          tinsert(res, {
            word = "('"..modname.."')",
            abbr = modname,
            menu = package.loaded[modname] ~= nil and 'module+' or 'module',
          })
        end
      end
    elseif e[3] == nil then
      tinsert(res, ')')
    end
    return res, e[1].col
  end
end

---@param src string
---@param env table
---@return string[]
function M.complete(src, env)
  env = env or _G
  local ts = parser.lex(src)
  local es = parser.parse(ts)

  local last = table.remove(es) ---@type nreplLuaExp
  if not last then return end
  local var = resolve(es, env)
  if not var then return end
  local completions, pos = complete(var, last)
  if pos then return completions, pos end

  -- TODO: if failed, complete from env
  -- local t = ts[#ts]
  -- if not t then return end
  -- if t.type == 'string' and t.incomplete then return end
  -- if t.type == 'comment' and t.incomplete then return end
  -- local e = { type = 'root', {  } }
  -- return complete(env, e)
end

return M
