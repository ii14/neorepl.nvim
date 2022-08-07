local api, fn, setl = vim.api, vim.fn, vim.opt_local
local util = require('neorepl.putil')
local bufs = require('neorepl.bufs')
local map = require('neorepl.map')
local Buf = require('neorepl.buf')
local Lua = require('neorepl.lua')
local Vim = require('neorepl.vim')
local Hist = require('neorepl.hist')
local COMMANDS = require('neorepl.cmd')

local COMMAND_PREFIX = '/'
local MSG_INVALID_COMMAND = {'invalid command'}

---No-op command for clearing undo history
local NOP_CHANGE = api.nvim_replace_termcodes('normal! a <BS><C-G>u<Esc>', true, false, true)

---@generic T
---@param v T|nil
---@param default T
---@return T
local function get_opt(v, default)
  if v == nil then
    return default
  else
    return v
  end
end

---@alias neorepl.Mode neorepl.Lua|neorepl.Vim

---@class neorepl.Repl
---@field bufnr   number        buffer number
---@field buf     neorepl.Buf   repl buffer
---@field hist    neorepl.Hist  command history
---@field lua     neorepl.Lua   lua evaluator
---@field vim     neorepl.Vim   vim evaluator
---@field mode    neorepl.Mode  current evaluator
---Options:
---@field buffer  number        buffer context
---@field window  number        window context
---@field inspect boolean       inspect variables
---@field indent  number        indent level
local Repl = {}
Repl.__index = Repl

---Create a new REPL instance
---@param config? neorepl.Config
---@return neorepl.Repl
function Repl.new(config)
  if config.buffer then
    config.buffer = util.parse_buffer(config.buffer, true)
    assert(config.buffer, 'invalid window')
  end
  if config.window then
    config.window = util.parse_window(config.window, true)
    assert(config.window, 'invalid window')
  end

  vim.cmd('enew')
  local bufnr = api.nvim_get_current_buf()

  setl.buftype = 'nofile'
  setl.swapfile = false
  setl.undofile = false
  setl.number = false
  setl.relativenumber = false
  setl.signcolumn = 'yes'
  setl.keywordprg = ':help'
  map.define()
  api.nvim_buf_set_name(bufnr, 'neorepl://neorepl('..bufnr..')')
  -- set filetype after mappings and settings to allow overriding in ftplugin
  api.nvim_buf_set_option(bufnr, 'filetype', 'neorepl')
  vim.cmd([[syn match neoreplLinebreak "^\\"]])

  ---@type neorepl.Repl
  local self = setmetatable({
    bufnr = bufnr,
    buf = Buf.new(bufnr),
    buffer = config.buffer or 0,
    window = config.window or 0,
    inspect = get_opt(config.inspect, true),
    indent = get_opt(config.indent, 0),
    hist = Hist.new(config),
    config = config,
  }, Repl)

  self.lua = Lua.new(self, config)
  self.vim = Vim.new(self, config)
  self.mode = config.lang == 'vim' and self.vim or self.lua

  bufs[bufnr] = self
  api.nvim_create_autocmd('BufDelete', {
    group = api.nvim_create_augroup('neorepl', { clear = false }),
    buffer = bufnr,
    callback = function()
      self.buf.listener.detach()
      bufs[bufnr] = nil
    end,
    desc = 'neorepl: close repl',
    once = true,
  })

  if config.on_init then
    config.on_init(bufnr)
  end
  if config.startinsert then
    vim.cmd('startinsert')
  end

  return self
end

---Get lines under cursor
---@return string[] lines, integer start, integer end
function Repl:get_line()
  assert(api.nvim_win_get_buf(0) == self.bufnr)
  return Buf.get_line(0)
end

---Append lines to the buffer
---@param lines string[]  lines
---@param hlgroup string  highlight group
function Repl:put(lines, hlgroup)
  if self.indent > 0 then
    local copy = {}
    local prefix = (' '):rep(self.indent)
    for i, line in ipairs(lines) do
      copy[i] = prefix .. line
    end
    lines = copy
  end
  self.buf:append(lines, hlgroup)
end

---Append prompt line
function Repl:new_line()
  api.nvim_buf_call(self.bufnr, function()
    Buf.prompt(self.bufnr) -- Append new prompt
    -- Undoing output messes with extmarks. Clear undo history
    local save = api.nvim_buf_get_option(self.bufnr, 'undolevels')
    api.nvim_buf_set_option(self.bufnr, 'undolevels', -1)
    api.nvim_command(NOP_CHANGE)
    api.nvim_buf_set_option(self.bufnr, 'undolevels', save)
  end)
end

---Clear buffer
function Repl:clear()
  Buf.clear(self.bufnr)
end

---Validate context
---@return nil|string[] error lines, nil if ok
function Repl:validate_context()
  local lines = {}
  if self.buffer ~= 0 and not api.nvim_buf_is_valid(self.buffer) then
    self.buffer = 0
    table.insert(lines, 'buffer deleted, setting it back to 0')
  end
  if self.window ~= 0 and not api.nvim_win_is_valid(self.window) then
    self.window = 0
    table.insert(lines, 'window deleted, setting it back to 0')
  end
  if #lines > 0 then
    return lines
  end
end

---Evaluate current line
function Repl:eval_line()
  -- reset history position
  self.hist:reset_pos()

  local lines = self:get_line()
  -- Ignore if it's only whitespace
  if not lines or util.lines_empty(lines) then
    self:new_line()
    return
  end

  -- Save lines to history
  self.hist:append(lines)

  -- REPL command
  local line = lines[1]
  if line:sub(1,1) == COMMAND_PREFIX then
    line = line:sub(2)
    local cmd, rest = line:match('^(%a*)%s*(.*)$')
    if not cmd then
      self:put(MSG_INVALID_COMMAND, 'neoreplError')
      self:new_line()
      return
    end

    -- Copy lines and trim command
    local args = { rest }
    for i = 2, #lines do
      args[i] = lines[i]
    end

    if util.lines_empty(args) then
      args = nil
    elseif #args == 1 then
      -- Trim trailing whitespace
      args[1] = args[1]:match('^(.-)%s*$')
    end

    for _, c in ipairs(COMMANDS) do
      if c.pattern == nil then
        local name = c.command
        c.pattern = '\\v\\C^'..name:sub(1,1)..'%['..name:sub(2)..']$'
      end

      if fn.match(cmd, c.pattern) >= 0 then
        -- Don't append new line when command returns false
        if c.run(args, self) ~= false then
          self:new_line()
        end
        return
      end
    end

    self:put(MSG_INVALID_COMMAND, 'neoreplError')
    self:new_line()
    return
  end

  local quit = self.mode:eval(lines) == false
  -- stop insert mode if buffer changed
  if api.nvim_get_current_buf() ~= self.bufnr then
    -- TODO: would be nice if it wasn't deferred.
    -- I think it's because it runs from an expr mapping?
    vim.schedule(function()
      api.nvim_command('stopinsert')
    end)
  end
  if quit then return end

  -- Validate buffer and window after evaluation
  local elines = self:validate_context()
  if elines then
    self:put(elines, 'neoreplInfo')
  end
  self:new_line()
end

---Execute function in current buffer/window context
---@param f function
function Repl:exec_context(f)
  -- Validate buffer and window
  local elines = self:validate_context()
  if elines then
    table.insert(elines, 'operation cancelled')
    self:put(elines, 'neoreplError')
    return false
  end

  if self.window > 0 then
    if self.buffer > 0 then
      api.nvim_win_call(self.window, function()
        api.nvim_buf_call(self.buffer, f)
      end)
    else
      api.nvim_win_call(self.window, f)
    end
  elseif self.buffer > 0 then
    api.nvim_buf_call(self.buffer, f)
  else
    f()
  end

  return true
end

---Move between entries in history
---@param prev boolean previous entry if true, next entry if false
function Repl:hist_move(prev)
  if self.hist:len() == 0 then return end
  local lines, s, e = self:get_line()
  if lines == nil then return end
  local nlines = self.hist:move(prev, lines)
  for i = 2, #nlines do
    nlines[i] = '\\' .. nlines[i]
  end
  api.nvim_buf_set_lines(self.bufnr, s - 1, e, true, nlines)
  api.nvim_win_set_cursor(0, { s + #nlines - 1, #nlines[#nlines] })
end

---Get completion
---@return integer offset, string[] completions
function Repl:get_completion()
  assert(api.nvim_get_current_buf() == self.bufnr, 'Not in neorepl buffer')
  assert(api.nvim_win_get_buf(0) == self.bufnr, 'Not in neorepl window')

  local line = api.nvim_get_current_line()
  local pos = api.nvim_win_get_cursor(0)[2]
  line = line:sub(1, pos)
  local results, start

  if line:sub(1,1) == COMMAND_PREFIX then
    line = line:sub(2)
    -- TODO: complete command arguments too
    if line:match('^%S*$') then
      results = {}
      local size = #line
      for _, c in ipairs(COMMANDS) do
        if line == c.command:sub(1, size) then
          table.insert(results, c.command)
        end
      end
      if #results > 0 then
        return 2, results
      end
      return
    end

    -- TODO: complete multiple lines
    local begin = fn.match(line, [[\v\C^v%[im]\s+\zs]])
    if begin >= 0 then
      start, results = self.vim:complete(line:sub(begin + 1))
    else
      begin = fn.match(line, [[\v\C^l%[ua]\s+\zs]])
      if begin < 0 then return end
      start, results = self.lua:complete(line:sub(begin + 1))
    end
    if start then
      start = start + begin + 1
    end

    if results and #results > 0 then
      return start or pos + 1, results
    end
    return
  end

  -- TODO: complete multiple lines
  start, results = self.mode:complete(line)
  if results and #results > 0 then
    return start or pos + 1, results
  end
end

---Complete word under cursor
function Repl:complete()
  local offset, candidates = self:get_completion()
  if offset and #candidates > 0 then
    fn.complete(offset, candidates)
  end
end

---Go to previous/next output implementation
---@param backward boolean
---@param to_end? boolean
function Repl:goto_output(backward, to_end, count)
  Buf.goto_output(backward, to_end, count)
end

api.nvim_set_hl(0, 'neoreplError',     { default = true, link = 'ErrorMsg' })
api.nvim_set_hl(0, 'neoreplOutput',    { default = true, link = 'String' })
api.nvim_set_hl(0, 'neoreplValue',     { default = true, link = 'Number' })
api.nvim_set_hl(0, 'neoreplInfo',      { default = true, link = 'Function' })
api.nvim_set_hl(0, 'neoreplLinebreak', { default = true, link = 'Function' })

return Repl
