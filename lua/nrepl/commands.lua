local api = vim.api
local fn = vim.fn
local nrepl = require('nrepl')
local ns = api.nvim_create_namespace('nrepl')

local MSG_VIM = {'-- VIMSCRIPT --'}
local MSG_LUA = {'-- LUA --'}
local MSG_ARGS_NOT_ALLOWED = {'arguments not allowed for this command'}
local MSG_INVALID_BUF = {'invalid buffer'}
local MSG_INVALID_WIN = {'invalid window'}
-- local MSG_NOT_IMPLEMENTED = {'not implemented'}

local BUF_EMPTY = '[No Name]'

---@class nreplCommand
---@field command string
---@field description? string
---@field run function(args: string, repl: nreplRepl)

---@type nreplCommand[]
local COMMANDS = {}

table.insert(COMMANDS, {
  command = 'lua',
  description = 'switch to lua or evaluate expression',
  ---@param args string
  ---@param repl nreplRepl
  run = function(args, repl)
    if args then
      repl:eval_lua(args)
    else
      repl.vim_mode = false
      repl:put(MSG_LUA, 'nreplInfo')
    end
  end,
})

table.insert(COMMANDS, {
  command = 'vim',
  description = 'switch to vimscript or evaluate expression',
  ---@param args string
  ---@param repl nreplRepl
  run = function(args, repl)
    if args then
      repl:eval_vim(args)
    else
      repl.vim_mode = true
      repl:put(MSG_VIM, 'nreplInfo')
    end
  end,
})

table.insert(COMMANDS, {
  command = 'buffer',
  description = 'option: buffer context (number or string, 0 to disable)',
  ---@param args string
  ---@param repl nreplRepl
  run = function(args, repl)
    if args then
      local bufnr = require('nrepl.util').parse_buffer(args)
      if bufnr == 0 then
        repl.buffer = 0
        repl:put({'buffer: none'}, 'nreplInfo')
      elseif bufnr then
        repl.buffer = bufnr
        local bufname = fn.bufname(repl.buffer)
        if bufname == '' then
          bufname = BUF_EMPTY
        end
        repl:put({'buffer: '..repl.buffer..' ('..bufname..')'}, 'nreplInfo')
      else
        repl:put(MSG_INVALID_BUF, 'nreplError')
      end
    else
      if repl.buffer > 0 then
        if fn.bufnr(repl.buffer) >= 0 then
          local bufname = fn.bufname(repl.buffer)
          if bufname == '' then
            bufname = BUF_EMPTY
          end
          repl:put({'buffer: '..repl.buffer..' ('..bufname..')'}, 'nreplInfo')
        else
          repl:put({'buffer: '..repl.buffer..' [invalid]'}, 'nreplInfo')
        end
      else
        repl:put({'buffer: none'}, 'nreplInfo')
      end
    end
  end,
})

table.insert(COMMANDS, {
  command = 'window',
  description = 'option: window context (number, 0 to disable)',
  ---@param args string
  ---@param repl nreplRepl
  run = function(args, repl)
    if args then
      local winid = require('nrepl.util').parse_window(args)
      if winid == 0 then
        repl.window = 0
        repl:put({'window: none'}, 'nreplInfo')
      elseif winid then
        repl.window = winid
        repl:put({'window: '..repl.window}, 'nreplInfo')
      else
        repl:put(MSG_INVALID_WIN, 'nreplError')
      end
    else
      if repl.window > 0 then
        if api.nvim_win_is_valid(repl.window) then
          repl:put({'window: '..repl.window}, 'nreplInfo')
        else
          repl:put({'window: '..repl.window..' [invalid]'}, 'nreplInfo')
        end
      else
        repl:put({'window: none'}, 'nreplInfo')
      end
    end
  end,
})

table.insert(COMMANDS, {
  command = 'inspect',
  description = 'option: inspect returned lua values (boolean)',
  ---@param args string
  ---@param repl nreplRepl
  run = function(args, repl)
    if args == 't' or args == 'true' then
      repl.inspect = true
      repl:put({'inspect: '..tostring(repl.inspect)}, 'nreplInfo')
    elseif args == 'f' or args == 'false' then
      repl.inspect = false
      repl:put({'inspect: '..tostring(repl.inspect)}, 'nreplInfo')
    elseif args == nil then
      repl:put({'inspect: '..tostring(repl.inspect)}, 'nreplInfo')
    else
      repl:put({'invalid argument, expected t/f/true/false'}, 'nreplError')
    end
  end,
})

table.insert(COMMANDS, {
  command = 'indent',
  description = 'option: output indentation (number)',
  ---@param args string
  ---@param repl nreplRepl
  run = function(args, repl)
    if args then
      local value = args:match('^%d+$')
      if value then
        value = tonumber(value)
        if value < 0 or value > 32 then
          repl:put({'invalid argument, expected number in range 0 to 32'}, 'nreplError')
        elseif value == 0 then
          repl.indent = 0
          repl.indentstr = nil
          repl:put({'indent: '..repl.indent}, 'nreplInfo')
        else
          repl.indent = value
          repl.indentstr = string.rep(' ', value)
          repl:put({'indent: '..repl.indent}, 'nreplInfo')
        end
      else
        repl:put({'invalid argument, expected number in range 0 to 32'}, 'nreplError')
      end
    else
      repl:put({'indent: '..repl.indent}, 'nreplInfo')
    end
  end,
})

table.insert(COMMANDS, {
  command = 'redraw',
  description = 'option: redraw after evaluation (boolean)',
  ---@param args string
  ---@param repl nreplRepl
  run = function(args, repl)
    if args == 't' or args == 'true' then
      repl.redraw = true
      repl:put({'redraw: '..tostring(repl.redraw)}, 'nreplInfo')
    elseif args == 'f' or args == 'false' then
      repl.redraw = false
      repl:put({'redraw: '..tostring(repl.redraw)}, 'nreplInfo')
    elseif args == nil then
      repl:put({'redraw: '..tostring(repl.redraw)}, 'nreplInfo')
    else
      repl:put({'invalid argument, expected t/f/true/false'}, 'nreplError')
    end
  end,
})

table.insert(COMMANDS, {
  command = 'clear',
  description = 'clear buffer',
  ---@param args string
  ---@param repl nreplRepl
  run = function(args, repl)
    if args then
      repl:put(MSG_ARGS_NOT_ALLOWED, 'nreplError')
    else
      repl.mark_id = 1
      api.nvim_buf_clear_namespace(repl.bufnr, ns, 0, -1)
      api.nvim_buf_set_lines(repl.bufnr, 0, -1, false, {})
      return false
    end
  end,
})

table.insert(COMMANDS, {
  command = 'quit',
  description = 'close repl instance',
  ---@param args string
  ---@param repl nreplRepl
  run = function(args, repl)
    if args then
      repl:put(MSG_ARGS_NOT_ALLOWED, 'nreplError')
    else
      nrepl.close(repl.bufnr)
      return false
    end
  end,
})

table.insert(COMMANDS, {
  command = 'help',
  ---@param args string
  ---@param repl nreplRepl
  run = function(args, repl)
    if args then
      repl:put(MSG_ARGS_NOT_ALLOWED, 'nreplError')
    else
      local lines = {}
      for _, c in ipairs(COMMANDS) do
        if c.description then
          local cmd = '/'..c.command
          local pad = string.rep(' ', 12 - #cmd)
          table.insert(lines, cmd..pad..c.description)
        end
      end
      repl:put(lines, 'nreplInfo')
    end
  end,
})

return COMMANDS
