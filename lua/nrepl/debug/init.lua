---@class nreplDebugger
---@field thread thread
---@field func function
---@field status 'running'|'suspended'|'normal'|'dead'
---@field next fun(): boolean|number, number, string
---@field step fun(): boolean|number, number, string
---@field finish fun(): boolean|number, number, string
---@field continue fun(): boolean|number, number, string
---@field breakpoint fun(string,number): number

---@class nreplDebuggerLib
---@field create fun(function): nreplDebugger
---@field breakpoint fun()
local debugger = nil
local prev_print = _G.print

---@class nreplDebug
---@field repl nreplRepl      parent
---@field dbg nreplDebugger   debugged thread
---@field lastcmd string      last command
---@field print fun(...)      print function
local Debug = {}
Debug.__index = Debug

local function nested(i)
  i = (i or 0) + 1
  print('nested: '..i)
  return i
end

function Debug.example()
  print('example A')

  for i = 1, 3 do
    print('loop: '..i)
  end

  debugger.breakpoint()

  print('example B')

  local x = nested()
  x = nested(x)

  print('example C')
  print('example D')

  print('example E')
  print('example F')

  return x
end
-- "./lua/nrepl/debug/init.lua"

--- Create a new debugger
---@param repl nreplRepl
---@param _ nreplConfig
---@return nreplDebug
function Debug.new(repl, _)
  local this = setmetatable({
    repl = repl,
    lastcmd = '',
  }, Debug)

  -- print override
  this.print = function(...)
    local args = {...}
    for i, v in ipairs(args) do
      args[i] = tostring(v)
    end
    local lines = vim.split(table.concat(args, '\t'), '\n', { plain = true })
    repl:put(lines, 'nreplOutput')
  end

  debugger = require('nrepl.debug.debugger')
  this.dbg = debugger.create(Debug.example)
  return this
end

function Debug:eval(prg)
  assert(type(prg) == 'string')
  local res, line, src

  if prg == nil or prg == '' then
    prg = self.lastcmd
  else
    self.lastcmd = prg
  end

  _G.print = self.print
  if prg == 'n' then -- next
    res, line, src = self.dbg:next()
  elseif prg == 's' then -- step
    res, line, src = self.dbg:step()
  elseif prg == 'f' then -- finish
    res, line, src = self.dbg:finish()
  elseif prg == 'c' then -- continue
    res, line, src = self.dbg:continue()
  elseif prg:match('^b%s') then
    local bsrc, bline = prg:match('^b%s+([^:]+):(%d+)$')
    if line then bline = tonumber(line) end
    if bsrc and bline > 0 then
      local bp = self.dbg:breakpoint(bsrc, tonumber(bline))
      self.repl:put({'new breakpoint: #'..bp}, 'nreplError')
    else
      self.repl:put({'invalid breakpoint'}, 'nreplError')
    end
  elseif prg == 'bt' then -- backtrace
    local out = {}
    do local level = 0; while true do
      local i = debug.getinfo(self.dbg.thread, level)
      if not i then break end
      table.insert(out, string.format('#%d %s:%d', level, i.source, i.currentline))
      level = level + 1
    end end

    if #out > 0 then
      self.repl:put(out, 'nreplValue')
    else
      self.repl:put({'empty'}, 'nreplWarn')
    end
  elseif prg == 'l' or prg:match('^l%s*%d+$') then -- locals
    local lvl = prg:match('^l%s*(%d+)$')
    lvl = tonumber(lvl) or 0
    local ok = true
    local out = {}
    do local i = 0; while true do
      i = i + 1
      local key, value
      ok, key, value = pcall(debug.getlocal, self.dbg.thread, lvl, i)
      if not ok or not key then break end
      value = tostring(value):gsub('\n', '\\n')
      table.insert(out, string.format('#%d %s = %s', i, key, value))
    end end

    if #out > 0 then
      self.repl:put(out, 'nreplValue')
    elseif ok then
      self.repl:put({'empty'}, 'nreplWarn')
    else
      self.repl:put({'out of bounds'}, 'nreplError')
    end
  elseif prg == 'u' then -- upvalues
    local func = debug.getinfo(self.dbg.thread, 0, 'f').func
    local out = {}
    do local i = 0; while true do
      i = i + 1
      local key, value = debug.getupvalue(func, i)
      if not key then break end
      value = tostring(value):gsub('\n', '\\n')
      table.insert(out, string.format('#%d %s = %s', i, key, value))
    end end

    if #out > 0 then
      self.repl:put(out, 'nreplValue')
    else
      self.repl:put({'empty'}, 'nreplWarn')
    end
  else
    self.repl:put({'invalid debugger command'}, 'nreplError')
  end
  _G.print = prev_print

  if res == true then
    self.repl:put({'Thread returned successfully'}, 'nreplInfo')
  elseif res == false then
    self.repl:put({'Exception: '..line}, 'nreplError')
  elseif res then
    local str = (src or '??')..':'..(line or '??')
    if res > 0 then
      str = str..' breakpoint #'..res
    end
    self.repl:put({str}, 'nreplInfo')
  end
end

return Debug
