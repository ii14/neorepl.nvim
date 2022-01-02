local api = vim.api
local fn = vim.fn
local nrepl = require('nrepl')
local ns = api.nvim_create_namespace('nrepl')

local MSG_VIM = {'-- VIMSCRIPT --'}
local MSG_LUA = {'-- LUA --'}
local MSG_ARGS_NOT_ALLOWED = {'arguments not allowed for this command'}
local MSG_INVALID_BUF = {'invalid buffer'}
local MSG_NOT_IMPLEMENTED = {'not implemented'}

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
  description = 'change buffer context (0 to disable) or print current value',
  ---@param args string
  ---@param repl nreplRepl
  run = function(args, repl)
    if args then
      local num = args:match('^%d+$')
      if num then args = tonumber(num) end
      if args == 0 then
        repl.buffer = 0
        repl:put({'buffer: none'}, 'nreplInfo')
      else
        local value = fn.bufnr(args)
        if value >= 0 then
          repl.buffer = value
          local bufname = fn.bufname(repl.buffer)
          if bufname == '' then
            bufname = BUF_EMPTY
          end
          repl:put({'buffer: '..repl.buffer..' '..bufname}, 'nreplInfo')
        else
          repl:put(MSG_INVALID_BUF, 'nreplError')
        end
      end
    else
      if repl.buffer > 0 then
        if fn.bufnr(repl.buffer) >= 0 then
          local bufname = fn.bufname(repl.buffer)
          if bufname == '' then
            bufname = BUF_EMPTY
          end
          repl:put({'buffer: '..repl.buffer..' '..bufname}, 'nreplInfo')
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
  description = 'NOT IMPLEMENTED: change window context',
  ---@param repl nreplRepl
  run = function(_, repl)
    repl:put(MSG_NOT_IMPLEMENTED, 'nreplError')
  end,
})

table.insert(COMMANDS, {
  command = 'indent',
  description = 'set indentation or print current value',
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
