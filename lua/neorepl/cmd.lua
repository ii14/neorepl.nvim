local api, fn = vim.api, vim.fn

local COMMAND_PREFIX = '/'

local MSG_VIM = {'-- VIMSCRIPT --'}
local MSG_LUA = {'-- LUA --'}
local MSG_ARGS_NOT_ALLOWED = {'arguments not allowed for this command'}
local MSG_MULTI_LINES_NOT_ALLOWED = {'multiple lines not allowed for this command'}
local MSG_INVALID_BUF = {'invalid buffer'}
local MSG_INVALID_WIN = {'invalid window'}
-- local MSG_NOT_IMPLEMENTED = {'not implemented'}

local BUF_EMPTY = '[No Name]'

---@class neorepl.Command
---@field command string
---@field description? string
---@field run function(args: string, repl: neorepl.Repl)

---@type neorepl.Command[]
local COMMANDS = {}

---Command for boolean options
---@param args string[]
---@param repl neorepl.Repl
local function command_boolean(args, repl)
  if args then
    if #args > 1 then
      repl:echo(MSG_MULTI_LINES_NOT_ALLOWED, 'neoreplError')
      return false
    else
      args = args[1]
    end
  end
  if args == 't' or args == 'true' then
    return true, true
  elseif args == 'f' or args == 'false' then
    return true, false
  elseif args == nil then
    return true, nil
  else
    repl:echo({'invalid argument, expected t/f/true/false'}, 'neoreplError')
    return false
  end
end


table.insert(COMMANDS, {
  command = 'lua',
  description = 'switch to lua or evaluate expression',
  ---@param args string
  ---@param repl neorepl.Repl
  run = function(args, repl)
    if args then
      local quit = repl.lua:eval(args) == false
      if api.nvim_get_current_buf() ~= repl.bufnr then
        api.nvim_command('stopinsert')
      end
      if quit then return end
      local elines = repl:_ctx_validate()
      if elines then
        repl:echo(elines, 'neoreplInfo')
      end
    else
      repl.mode = repl.lua
      repl:echo(MSG_LUA, 'neoreplInfo')
    end
  end,
})

table.insert(COMMANDS, {
  command = 'vim',
  description = 'switch to vimscript or evaluate expression',
  ---@param args string
  ---@param repl neorepl.Repl
  run = function(args, repl)
    if args then
      local quit = repl.vim:eval(args) == false
      if api.nvim_get_current_buf() ~= repl.bufnr then
        api.nvim_command('stopinsert')
      end
      if quit then return end
      local elines = repl:_ctx_validate()
      if elines then
        repl:echo(elines, 'neoreplInfo')
      end
    else
      repl.mode = repl.vim
      repl:echo(MSG_VIM, 'neoreplInfo')
    end
  end,
})

table.insert(COMMANDS, {
  command = 'buffer',
  description = 'option: buffer context (number or string, 0 to disable)',
  ---@param args string
  ---@param repl neorepl.Repl
  run = function(args, repl)
    if args then
      if #args > 1 then
        repl:echo(MSG_MULTI_LINES_NOT_ALLOWED, 'neoreplError')
        return
      end
      local bufnr = require('neorepl.putil').parse_buffer(args[1])
      if bufnr == 0 then
        repl.buffer = 0
        repl:echo({'buffer: none'}, 'neoreplInfo')
      elseif bufnr then
        repl.buffer = bufnr
        local bufname = fn.bufname(repl.buffer)
        if bufname == '' then
          bufname = BUF_EMPTY
        else
          bufname = '('..bufname..')'
        end
        repl:echo({'buffer: '..repl.buffer..' '..bufname}, 'neoreplInfo')
      else
        repl:echo(MSG_INVALID_BUF, 'neoreplError')
      end
    else
      if repl.buffer > 0 then
        local bufname
        if fn.bufnr(repl.buffer) >= 0 then
          bufname = fn.bufname(repl.buffer)
          if bufname == '' then
            bufname = BUF_EMPTY
          else
            bufname = '('..bufname..')'
          end
        else
          bufname = '[invalid]'
        end
        repl:echo({'buffer: '..repl.buffer..' '..bufname}, 'neoreplInfo')
      else
        repl:echo({'buffer: none'}, 'neoreplInfo')
      end
    end
  end,
})

table.insert(COMMANDS, {
  command = 'window',
  description = 'option: window context (number, 0 to disable)',
  ---@param args string
  ---@param repl neorepl.Repl
  run = function(args, repl)
    if args then
      if #args > 1 then
        repl:echo(MSG_MULTI_LINES_NOT_ALLOWED, 'neoreplError')
        return
      end
      local winid = require('neorepl.putil').parse_window(args[1])
      if winid == 0 then
        repl.window = 0
        repl:echo({'window: none'}, 'neoreplInfo')
      elseif winid then
        repl.window = winid
        repl:echo({'window: '..repl.window}, 'neoreplInfo')
      else
        repl:echo(MSG_INVALID_WIN, 'neoreplError')
      end
    else
      if repl.window > 0 then
        if api.nvim_win_is_valid(repl.window) then
          repl:echo({'window: '..repl.window}, 'neoreplInfo')
        else
          repl:echo({'window: '..repl.window..' [invalid]'}, 'neoreplInfo')
        end
      else
        repl:echo({'window: none'}, 'neoreplInfo')
      end
    end
  end,
})

table.insert(COMMANDS, {
  command = 'inspect',
  description = 'option: inspect returned lua values (boolean)',
  ---@param args string
  ---@param repl neorepl.Repl
  run = function(args, repl)
    local ok, res = command_boolean(args, repl)
    if ok then
      if res ~= nil then
        repl.inspect = res
      end
      repl:echo({'inspect: '..tostring(repl.inspect)}, 'neoreplInfo')
    end
  end,
})

table.insert(COMMANDS, {
  command = 'indent',
  description = 'option: output indentation (number)',
  ---@param args string
  ---@param repl neorepl.Repl
  run = function(args, repl)
    if args then
      if #args > 1 then
        repl:echo(MSG_MULTI_LINES_NOT_ALLOWED, 'neoreplError')
        return
      end
      local value = args[1]:match('^%d+$')
      if value then
        value = tonumber(value)
        if value < 0 or value > 32 then
          repl:echo({'invalid argument, expected number in range 0 to 32'}, 'neoreplError')
        elseif value == 0 then
          repl.indent = 0
          repl:echo({'indent: '..repl.indent}, 'neoreplInfo')
        else
          repl.indent = value
          repl:echo({'indent: '..repl.indent}, 'neoreplInfo')
        end
      else
        repl:echo({'invalid argument, expected number in range 0 to 32'}, 'neoreplError')
      end
    else
      repl:echo({'indent: '..repl.indent}, 'neoreplInfo')
    end
  end,
})

table.insert(COMMANDS, {
  command = 'clear',
  description = 'clear buffer',
  ---@param args string
  ---@param repl neorepl.Repl
  run = function(args, repl)
    if args then
      repl:echo(MSG_ARGS_NOT_ALLOWED, 'neoreplError')
    else
      repl:clear()
      repl:prompt()
      return false
    end
  end,
})

table.insert(COMMANDS, {
  command = 'quit',
  description = 'close repl instance',
  ---@param args string
  ---@param repl neorepl.Repl
  run = function(args, repl)
    if args then
      repl:echo(MSG_ARGS_NOT_ALLOWED, 'neoreplError')
    else
      vim.cmd('stopinsert')
      require('neorepl.bufs')[repl.bufnr] = nil
      api.nvim_buf_delete(repl.bufnr, { force = true })
      return false
    end
  end,
})

table.insert(COMMANDS, {
  command = 'help',
  ---@param args string
  ---@param repl neorepl.Repl
  run = function(args, repl)
    if args then
      repl:echo(MSG_ARGS_NOT_ALLOWED, 'neoreplError')
    else
      local lines = {}
      for _, c in ipairs(COMMANDS) do
        if c.description then
          local cmd = COMMAND_PREFIX..c.command
          local pad = string.rep(' ', 12 - #cmd)
          table.insert(lines, cmd..pad..c.description)
        end
      end
      repl:echo(lines, 'neoreplInfo')
    end
  end,
})

return COMMANDS
