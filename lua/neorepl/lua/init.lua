local api = vim.api
---Reference to global print function
local prev_print = _G.print

---@class neorepl.Lua
---@field repl neorepl.Repl   parent
---@field env table           repl environment
---@field print fun(...)      print function
---@field interface table     user interface
---@field res table           last results
local Lua = {}
Lua.__index = Lua

---Create a new lua context
---@param repl neorepl.Repl
---@param config neorepl.Config
---@return neorepl.Lua
function Lua.new(repl, config)
  local self = setmetatable({ repl = repl }, Lua)

  self.res = {}
  self.interface = { res = self.res }

  -- print override
  self.print = function(...)
    local args = {...}
    for i, v in ipairs(args) do
      args[i] = tostring(v)
    end
    local lines = vim.split(table.concat(args, '\t'), '\n', { plain = true })
    repl:echo(lines, 'neoreplOutput')
  end

  self.env = setmetatable({
    ---print function override
    print = self.print,
    repl = self.interface,
  }, { __index = _G })

  -- add user environment
  local userenv = config.env_lua
  if userenv then
    (function()
      if type(userenv) == 'function' then
        local ok, res = pcall(userenv, self.env)
        if not ok then
          local err = vim.split(res, '\n', { plain = true })
          table.insert(err, 1, 'Error from user env:')
          repl:echo(err, 'neoreplError')
          return self.repl:prompt()
        elseif res == nil then
          return
        elseif type(res) ~= 'table' then
          repl:echo({'Result of user env is not a table'}, 'neoreplError')
          return self.repl:prompt()
        else
          userenv = res
        end
      end

      for k, v in pairs(userenv) do
        self.env[k] = v
      end
    end)()
  end

  return self
end

---@type function
---@param f function
---@return boolean ok, table results, number result count
local exec do
  ---Gather results from pcall
  local function pcall_res(ok, ...)
    if ok then
      -- return returned values as a table and its size,
      -- because when iterating ipairs will stop at nil
      return ok, {...}, select('#', ...)
    else
      return ok, ...
    end
  end

  function exec(f)
    local coro = coroutine.create(f)
    local ok, res, n = pcall_res(coroutine.resume(coro))
    if not ok and debug.getinfo(coro, 0, 'f').func ~= f then
      res = debug.traceback(coro, res, 0)
    end
    return ok, res, n
  end
end

---Evaluate lua and append output to the buffer
---@param prg string|string[]
---@return nil|boolean
function Lua:eval(prg)
  if type(prg) == 'table' then
    prg = table.concat(prg, '\n')
  end

  local ok, res, err, n
  if type(prg) == 'string' then
    res = loadstring('return '..prg, 'neorepl')
    if not res then
      res, err = loadstring(prg, 'neorepl')
    end
  elseif type(prg) == 'function' then
    res = prg
  else
    error('invalid prg type')
  end

  if res then
    setfenv(res, self.env)

    local ctxres = self.repl:_ctx_exec(function()
      -- temporarily replace print
      _G.print = self.print
      ok, res, n = exec(res)
      _G.print = prev_print
      vim.cmd('redraw')
    end)

    if not api.nvim_buf_is_valid(self.repl.bufnr) then
      return false
    elseif not ctxres then
      return
    elseif not ok then
      self.repl:echo(vim.split(res, '\n', { plain = true }), 'neoreplError')
    elseif #res > 0 then
      -- Save results
      for k in pairs(self.res) do
        self.res[k] = nil
      end
      for i = 1, n do
        self.res[i] = res[i]
      end

      -- Print results
      local stringify = self.repl.inspect and vim.inspect or tostring
      for i = 1, n do
        res[i] = stringify(res[i])
      end
      self.repl:echo(vim.split(table.concat(res, ', '), '\n', { plain = true }), 'neoreplValue')
    end
  elseif err:match("'<eof>'$") then
    -- more input expected, add line break
    api.nvim_buf_set_lines(self.repl.bufnr, -1, -1, false, {'\\'})
    vim.cmd('$')
    return false
  else
    self.repl:echo({err}, 'neoreplError')
  end
end

do
  local complete = nil
  ---Complete line
  ---@param line string
  ---@return integer offset, string[] completions
  function Lua:complete(line)
    if complete == nil then
      complete = require('neorepl.lua.complete').complete
    end

    -- merge environments on the fly, because
    -- I don't know how to do it cleanly otherwise
    local env = {}
    for k, v in pairs(_G) do
      env[k] = v
    end
    for k, v in pairs(self.env) do
      env[k] = v
    end

    -- TODO: concat with previous lines
    local results, pos = complete(line, env)
    if results and #results > 0 then
      return pos + 1, results
    end
  end
end

return Lua
