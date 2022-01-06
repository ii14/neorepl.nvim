--- Completion providers

local tinsert, tsort, tremove, tconcat = table.insert, table.sort, table.remove, table.concat
local slower = string.lower
local api, api_info = vim.api, vim.fn.api_info

local M = {}

do -- require completion
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
  function M.require(query)
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

do -- vim.api function signatures
  ---@type table<string,string[]>
  local NVIM_API = nil

  ---@return table<function,string[]>
  function M.api()
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

do -- vim.fn completion
  local VIM_FNS = nil

  local function function_sort(a, b)
    return slower(a[1]) < slower(b[1])
  end

  ---@param filter string
  ---@return string[][]
  function M.fn(filter)
    -- get all builtin functions
    if VIM_FNS == nil then
      VIM_FNS = {}
      for _, func in ipairs(require('nrepl.lua.data.functions')) do
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

do -- lua stdlib function signatures
  local STDLIB_FNS = nil
  function M.stdlib()
    if not STDLIB_FNS then
      STDLIB_FNS = require('nrepl.lua.data.stdlib')
    end
    return STDLIB_FNS
  end
end

return M
