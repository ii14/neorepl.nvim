local parser = require('nrepl.lua.parser')
local providers = require('nrepl.lua.providers')
local tinsert, tsort, tremove, tconcat = table.insert, table.sort, table.remove, table.concat
local dgetinfo, dgetlocal = debug.getinfo, debug.getlocal
local slower = string.lower
local ploaded = package.loaded

local M = {}

local RE_IDENT = '^[%a_][%a%d_]*$'

local function match(str, re)
  local ok, res = pcall(string.match, str, re)
  return ok and res
end

local function sort_completions(a, b)
  return slower(a.word) < slower(b.word)
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


---@param f function
---@return string[] argnames, boolean isvararg, boolean special
local function get_func_info(f)
  local api_func = providers.api()[f]
  if api_func then
    return api_func, false, true
  end

  ---@diagnostic disable: undefined-field
  local info = dgetinfo(f, 'u')
  local args = {}
  for i = 1, info.nparams do
    args[i] = dgetlocal(f, i)
  end
  if info.isvararg then
    tinsert(args, '...')
  end
  return args, info.isvararg, false
  ---@diagnostic enable: undefined-field
end


local function isindexable(v)
  if type(v) == 'table' then
    return true
  end
  local mt = getmetatable(v)
  return mt and mt.__index
end

---@param es nreplLuaExp[]
---@param env table
---@return any
local function resolve(es, env)
  local var = env or _G

  for _, e in ipairs(es) do
    if e.type == 'root' or e.type == 'prop' then
      if not isindexable(var) then return end
      local prop = var[e[e.type == 'root' and 1 or 2].value]
      if prop == nil then return end
      var = prop
    elseif e.type == 'index' then
      if not isindexable(var) then return end
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
      local prop = ploaded[r]
      if prop == nil then return end
      var = prop
    end
  end

  return var
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
    if not isindexable(var) then return end
    local res = {}
    local re = '^'..e[1].value

    for k, v in pairs(var) do
      if type(k) == 'string' and match(k, re) and k:match(RE_IDENT) then
        if type(v) == 'function' then
          local argnames, isvararg, special = get_func_info(v)
          tinsert(res, {
            word = k..((isvararg or #argnames > 0) and (v == require and "'" or '(') or '()'),
            abbr = k..'('..tconcat(argnames, ', ')..')',
            menu = special and 'function*' or 'function',
          })
        else
          tinsert(res, {
            word = k,
            abbr = k,
            menu = type(v),
          })
        end
      end
    end

    tsort(res, sort_completions)
    return res, e[1].col
  end

  if e.type == 'prop' then
    if not isindexable(var) then return end

    -- special handling for vim.fn
    if var == vim.fn then
      local res = providers.fn(e[2] and e[2].value or '')
      for i, v in ipairs(res) do
        local k = v[1]
        local argnames = v[2]
        local word = k:match(RE_IDENT) and '.'..k or "['"..k.."']"
        res[i] = {
          word = word..((#argnames > 0) and '(' or '()'),
          abbr = k..'('..argnames..')',
          menu = 'function*',
        }
      end
      return res, e[1].col
    end

    local res = {}
    local re = '^'..(e[2] and e[2].value or '')

    for k, v in pairs(var) do
      if type(k) == 'string' and match(k, re) then
        -- TODO: escape key
        local word = k:match(RE_IDENT) and '.'..k or "['"..k.."']"
        if type(v) == 'function' then
          local argnames, isvararg, special = get_func_info(v)
          tinsert(res, {
            word = word..((isvararg or #argnames > 0) and (v == require and "'" or '(') or '()'),
            abbr = k..'('..tconcat(argnames, ', ')..')',
            menu = special and 'function*' or 'function'
          })
        else
          tinsert(res, {
            word = word,
            abbr = k,
            menu = type(v),
          })
        end
      end
    end

    tsort(res, sort_completions)
    return res, e[1].col
  end

  if e.type == 'index' then
    -- TODO
    return
  end

  if e.type == 'method' then
    if not isindexable(var) then return end
    local res = {}
    local re = '^'..(e[2] and e[2].value or '')

    for k, v in pairs(var) do
      if type(k) == 'string' and match(k, re) and k:match(RE_IDENT) then
        if type(v) == 'function' then
          local argnames, isvararg, special = get_func_info(v)
          if #argnames > 0 then
            tinsert(res, {
              word = ':'..k..((isvararg or #argnames > 1) and '(' or '()'),
              abbr = k..'('..tconcat(argnames, ', ')..')',
              menu = special and 'function*' or 'function'
            })
          end
        end
      end
    end

    tsort(res, sort_completions)
    return res, e[1].col
  end

  if e.type == 'call1' then
    if var ~= require then return end
    local res = {}

    if e[1].incomplete and not e[1].long then
      if e[1].long then return end
      local stype = e[1].value:sub(1,1)
      for _, modname in ipairs(providers.require(e[1].value:sub(2))) do
        -- escape string?
        tinsert(res, {
          word = stype..modname..stype,
          abbr = modname,
          menu = ploaded[modname] ~= nil and 'module+' or 'module',
        })
      end
    end

    return res, e[1].col
  end

  if e.type == 'call2' then
    if var ~= require then return end
    local res = {}

    if e[2] == nil or e[2].incomplete then
      if e[2] then
        if e[2].long then return end
        local stype = e[2].value:sub(1,1)
        for _, modname in ipairs(providers.require(e[2].value:sub(2))) do
          -- escape string?
          tinsert(res, {
            word = '('..stype..modname..stype..')',
            abbr = modname,
            menu = ploaded[modname] ~= nil and 'module+' or 'module',
          })
        end
      else
        for _, modname in ipairs(providers.require()) do
          -- escape string?
          tinsert(res, {
            word = "('"..modname.."')",
            abbr = modname,
            menu = ploaded[modname] ~= nil and 'module+' or 'module',
          })
        end
      end
    elseif e[3] == nil then
      tinsert(res, ')')
    end

    return res, e[1].col
  end
end

local KEYWORDS_BEFORE_IDENT = require('nrepl.util').make_lookup {
  'and', 'do', 'else', 'elseif', 'end',
  'if', 'in', 'not', 'or', 'repeat',
  'return', 'then', 'until', 'while',
}

---@param src string
---@param env table
---@return string[]
function M.complete(src, env)
  local ts, endline, endcol = parser.lex(src)
  local es = parser.parse(ts)

  -- don't complete identifiers if there is a space after them
  local le = tremove(es) ---@type nreplLuaExp
  if le and le[#le].type ~= 'ident' or not src:sub(-1,-1):match('%s') then
    local var = resolve(es, env)
    if not var then return end
    local completions, pos = complete(var, le)
    if pos then return completions, pos end
  end

  local lt = ts[#ts]
  if lt then -- TODO: this is just basic stuff for now, probably needs a lot more
    -- stop after incomplete strings and comments
    if lt.incomplete then return end

    -- stop after . : ... operators
    if lt.type == 'op' and (lt.value == '.' or
       lt.value == ':' or lt.value == '...' or
       lt.value == '[' or lt.value == ']')
    then return end

    -- stop if there is no space after ident. keywords are fine tho
    if lt.type == 'ident' and
      (not src:sub(-1,-1):match('%s') or not KEYWORDS_BEFORE_IDENT[lt.value])
    then return end
  end

  --- complete from env, with a fake empty exp
  return complete(env, {
    type = 'root', {
      type = 'ident',
      value = '',
      line = endline,
      col = endcol,
    },
  })
end

return M
