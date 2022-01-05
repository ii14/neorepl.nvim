local M = {}

local lexer = require('nrepl.lua.lexer')
local tinsert = table.insert

---@type table<string,boolean>
local KEYWORDS do
  local function make_lookup(t)
    local r = {}
    for _, k in ipairs(t) do
      r[k] = true
    end
    return r
  end

  KEYWORDS = make_lookup {
    'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for',
    'function', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat',
    'return', 'then', 'true', 'until', 'while',
  }
end

local function match(str, re)
  local ok, res = pcall(string.match, str, re)
  return ok and res
end

---@alias nreplLuaExpType
---| 'root'     first variable to look up       = ident
---| 'prop'     property accessed through .     = . ident
---| 'index'    property accessed through []    = [ number|string ]
---| 'method'   method                          = : ident
---| 'call1'    function call 1                 = string
---| 'call2'    function call 2                 = ( string )

-- can't inherit from tables, so a union type instead

---@class nreplLuaExpBase
---@field type nreplLuaExpType
---@alias nreplLuaExp nreplLuaExpBase|nreplLuaToken[]

---@param ts nreplLuaToken[]
---@return nreplLuaExp[]
local function get_last_exp(ts)
  local r = {}
  local t = nil ---@type nreplLuaToken
  local i = 0

  local function next() ---@return nreplLuaToken
    i = i + 1
    t = ts[i]
    return t
  end

  while true do
    if not next() then return r end
    if t.type == 'ident' then
      if KEYWORDS[t.value] then goto again end
      tinsert(r, { type = 'root', t })

      while true do
        if not next() then return r end
        if t.type == 'op' then
          if t.value == '.' then
            local exp = { type = 'prop', t }
            tinsert(r, exp)

            if not next() then return r end
            if t.type ~= 'ident' then goto back end
            if KEYWORDS[t.value] then goto back end
            tinsert(exp, t)
          elseif t.value == '[' then
            local exp = { type = 'index', t }
            tinsert(r, exp)

            if not next() then return r end
            -- TODO: parse booleans
            if t.type ~= 'number' and t.type ~= 'string' then goto back end
            tinsert(exp, t)

            if not next() then return r end
            if t.type ~= 'op' and t.type ~= ']' then goto back end
            tinsert(exp, t)
          elseif t.value == ':' then
            local exp = { type = 'method', t }
            tinsert(r, exp)

            if not next() then return r end
            if t.type ~= 'ident' then goto back end
            tinsert(exp, t)

            if not next() then return r end
            goto back -- no point in parsing method calls
          elseif t.value == '(' then
            -- include function calls with string as an argument for require
            local exp = { type = 'call2', t }
            tinsert(r, exp)

            if not next() then return r end
            if t.type ~= 'string' then goto back end
            tinsert(exp, t)

            if not next() then return r end
            if t.type ~= 'op' and t.value ~= ')' then goto back end
            tinsert(exp, t)
          else goto back end
        elseif t.type == 'string' then
          -- include function calls with string as an argument for require
          tinsert(r, { type = 'call1', t })
        else goto back end
      end
    else
      goto again
    end

    ::back::
    i = i - 1
    t = ts[i]
    ::again::
    r = {}
  end
  return r
end

local function scandir_iterator(fs)
  local uv = vim.loop
  return function()
    local dirname, dirtype = uv.fs_scandir_next(fs)
    if dirname then
      return dirname, dirtype
    end
  end
end

-- TODO: module.path, module.cpath
-- TODO: look up module.loaded whether the 'a/b/c' style is used
local function get_modules(query)
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

local RE_IDENT = '^[%a_][%a%d_]*$'

---@param src string
---@param env table
---@return string[]|boolean
function M.parse(src, env)
  local ts = lexer.lex(src) ---@type nreplLuaToken[]
  local es = get_last_exp(ts)
  local last = table.remove(es) ---@type nreplLuaExp

  -- resolve references leading up to the last element
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

  -- complete last element
  -- TODO: refactor
  if last then
    local e = last
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
              tinsert(res, k..'(')
            else
              tinsert(res, k..'()')
            end
          elseif type(v) == 'table' then
            tinsert(res, k..'.')
          else
            tinsert(res, k)
          end
        end
      end

      table.sort(res)
      return e[1].col, res
    elseif e.type == 'prop' then
      if type(var) ~= 'table' then return end
      local res = {}
      local re = '^'..(e[2] and e[2].value or '')

      for k, v in pairs(var) do
        if type(k) == 'string' and match(k, re) then
          if not k:match(RE_IDENT) then
            -- TODO: escape key
            k = "['"..k.."']"
          else
            k = '.'..k
          end
          if type(v) == 'function' then
            local i = debug.getinfo(v, 'u')
            ---@diagnostic disable-next-line: undefined-field
            if i.isvararg or i.nparams > 0 then
              tinsert(res, k..'(')
            else
              tinsert(res, k..'()')
            end
          elseif type(v) == 'table' then
            tinsert(res, k..'.')
          else
            tinsert(res, k)
          end
        end
      end

      table.sort(res)
      return e[1].col, res
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
              tinsert(res, ':'..k..'(')
            ---@diagnostic disable-next-line: undefined-field
            elseif i.nparams > 0 then
              tinsert(res, ':'..k..'()')
            end
          end
        end
      end

      table.sort(res)
      return e[1].col, res
    elseif e.type == 'call1' then
      if var ~= require then return end
      local res = {}
      if e[1].incomplete and not e[1].long then
        if e[1].long then return end
        local stype = e[1].value:sub(1,1)
        for _, modname in ipairs(get_modules(e[1].value:sub(2))) do
          -- escape string?
          tinsert(res, stype..modname..stype)
        end
      end
      return e[1].col, res
    elseif e.type == 'call2' then
      if var ~= require then return end
      local res = {}
      if e[2] == nil or e[2].incomplete then
        if e[2] then
          if e[2].long then return end
          local stype = e[2].value:sub(1,1)
          for _, modname in ipairs(get_modules(e[2].value:sub(2))) do
            -- escape string?
            tinsert(res, '('..stype..modname..stype..')')
          end
        else
          for _, modname in ipairs(get_modules()) do
            -- escape string?
            tinsert(res, "('"..modname.."')")
          end
        end
      elseif e[3] == nil then
        tinsert(res, ')')
      end
      return e[1].col, res
    end
  end
end

---@param src string
---@param env table
---@return string[]|boolean
function M.complete(src, env)
  return M.parse(src, env)
end

return M
