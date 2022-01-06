local parser = require('nrepl.lua.parser')
local tinsert, tsort, tremove, tconcat = table.insert, table.sort, table.remove, table.concat
local dgetinfo, dgetlocal = debug.getinfo, debug.getlocal
local slower = string.lower
local ploaded = package.loaded
local fn, api, api_info = vim.fn, vim.api, vim.fn.api_info

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


---@type function
---@param query string
---@return string[]
local get_modules do
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

  function get_modules(query)
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
    local last = tremove(query) or ''
    local suffix = '/lua'
    local modbase
    if #query > 0 then
      suffix = suffix..'/'..tconcat(query, '/')
      modbase = tconcat(query, '.')
    end

    for _, path in ipairs(api.nvim_list_runtime_paths()) do
      scan(path..suffix, modbase, last)
    end
    tsort(res)
    return res
  end
end

---@type function
---@return table<string,string[]>
local get_nvim_api do
  ---@type table<string,string[]>
  local NVIM_API = nil
  function get_nvim_api()
    if NVIM_API then
      return NVIM_API
    end

    local info = {}
    for _, func in ipairs(api_info().functions) do
      local params = func.parameters
      for i, v in ipairs(params) do
        params[i] = v[2]
      end
      info[func.name] = params
    end

    NVIM_API = {}
    for k, v in pairs(api) do
      local params = info[k]
      if params then
        NVIM_API[v] = params
      end
    end
    return NVIM_API
  end
end

---@type function
---@param filter string
---@return table
local get_vim_functions do
  VIM_FNS = nil

  local function function_sort(a, b)
    return slower(a[1]) < slower(b[1])
  end

  function get_vim_functions(filter)
    -- get all builtin functions
    if VIM_FNS == nil then
      VIM_FNS = {}
      for _, func in ipairs(require('nrepl.vim.functions')) do
        if VIM_FNS[func[1]] == nil then
          VIM_FNS[func[1]] = func[2]
        end
      end
    end

    local size = #filter
    local res = {}

    -- match builtin functions
    for name, args in pairs(VIM_FNS) do
      if size == 0 or name:sub(1, size) == filter then
        tinsert(res, {name, args})
      end
    end

    -- match user functions
    for _, line in ipairs(vim.split(api.nvim_exec('function', true), '\n')) do
      local name, args = line:match('^function%s+([%a_][%a%d_#]*)%((.*)%)')
      if name ~= nil and (size == 0 or name:sub(1, size) == filter) then
        tinsert(res, {name, args})
      end
    end

    tsort(res, function_sort)
    return res
  end
end

---@param f function
---@return number nparams, number isvararg, string[] argnames
local function get_func_info(f)
  local api_func = get_nvim_api()[f]
  if api_func then return #api_func, false, api_func end

  ---@diagnostic disable: undefined-field
  local info = dgetinfo(f, 'u')
  local args = {}
  for i = 1, info.nparams do
    args[i] = dgetlocal(f, i)
  end
  if info.isvararg then
    tinsert(args, '...')
  end
  return info.nparams, info.isvararg, args
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
          local nparams, isvararg, argnames = get_func_info(v)
          tinsert(res, {
            word = k..((isvararg or nparams > 0) and (v == require and "'" or '(') or '()'),
            abbr = k..'('..tconcat(argnames, ', ')..')',
            menu = type(v),
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
    if var == fn then
      local res = get_vim_functions(e[2] and e[2].value or '')
      for i, v in ipairs(res) do
        local k = v[1]
        local argnames = v[2]
        local word = k:match(RE_IDENT) and '.'..k or "['"..k.."']"
        res[i] = {
          word = word..((#argnames > 0) and '(' or '()'),
          abbr = k..'('..argnames..')',
          menu = 'function',
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
          local nparams, isvararg, argnames = get_func_info(v)
          tinsert(res, {
            word = word..((isvararg or nparams > 0) and (v == require and "'" or '(') or '()'),
            abbr = k..'('..tconcat(argnames, ', ')..')',
            menu = type(v),
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
          local nparams, isvararg, argnames = get_func_info(v)
          if nparams > 0 then
            tinsert(res, {
              word = ':'..k..((isvararg or nparams > 1) and '(' or '()'),
              abbr = k..'('..tconcat(argnames, ', ')..')',
              menu = type(v),
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
      for _, modname in ipairs(get_modules(e[1].value:sub(2))) do
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
        for _, modname in ipairs(get_modules(e[2].value:sub(2))) do
          -- escape string?
          tinsert(res, {
            word = '('..stype..modname..stype..')',
            abbr = modname,
            menu = ploaded[modname] ~= nil and 'module+' or 'module',
          })
        end
      else
        for _, modname in ipairs(get_modules()) do
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
