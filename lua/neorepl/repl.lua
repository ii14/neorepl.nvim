local api, fn = vim.api, vim.fn
local util = require('neorepl.util')
local Buf = require('neorepl.buf')

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

---@class neorepl.Repl
---@field bufnr       number        buffer number
---@field buf         neorepl.Buf   repl buffer
---@field hist        neorepl.Hist  command history
---@field lua         neorepl.Lua   lua evaluator
---@field vim         neorepl.Vim   vim evaluator
---@field vim_mode    boolean       vim/lua mode
---Options:
---@field buffer      number        buffer context
---@field window      number        window context
---@field inspect     boolean       inspect variables
---@field indent      number        indent level
---@field redraw      boolean       redraw after evaluation (deprecated)
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

  require('neorepl.map').define()

  if config.no_defaults ~= true then
    require('neorepl.map').define_defaults()
    -- vim.opt_local.completeopt = 'menu'
  end

  vim.opt_local.buftype = 'nofile'
  vim.opt_local.swapfile = false
  vim.opt_local.undofile = false
  vim.opt_local.number = false
  vim.opt_local.relativenumber = false
  vim.opt_local.signcolumn = 'yes'
  vim.opt_local.backspace = 'indent,start'
  api.nvim_buf_set_name(bufnr, 'neorepl://neorepl('..bufnr..')')
  -- set filetype after mappings and settings to allow overriding in ftplugin
  api.nvim_buf_set_option(bufnr, 'filetype', 'neorepl')
  vim.cmd([[syn match neoreplLinebreak "^\\"]])

  ---@type neorepl.Repl
  local self = setmetatable({
    bufnr = bufnr,
    buf = Buf.new(bufnr), -- TODO: clean up
    buffer = config.buffer or 0,
    window = config.window or 0,
    vim_mode = config.lang == 'vim',
    redraw = get_opt(config.redraw, true),
    inspect = get_opt(config.inspect, true),
    indent = get_opt(config.indent, 0),
    hist = require('neorepl.hist').new(config),
  }, Repl)

  self.lua = require('neorepl.lua').new(self, config)
  self.vim = require('neorepl.vim').new(self, config)

  return self
end

---Append lines to the buffer
---@param lines string[]  lines
---@param hlgroup string  highlight group
function Repl:put(lines, hlgroup)
  self.buf:append(lines, hlgroup)
end

function Repl:clear()
  Buf.clear(self.bufnr)
end

---Append empty line
function Repl:new_line()
  Buf.prompt(self.bufnr) -- Append new prompt
  -- Undoing output messes with extmarks. Clear undo history
  local save = api.nvim_buf_get_option(self.bufnr, 'undolevels')
  api.nvim_buf_set_option(self.bufnr, 'undolevels', -1)
  api.nvim_command(NOP_CHANGE)
  api.nvim_buf_set_option(self.bufnr, 'undolevels', save)
end

---Get lines under cursor
---Returns nil on illegal line break
---@return string[]|nil
function Repl:get_line()
  assert(api.nvim_win_get_buf(0) == self.bufnr)
  return Buf.get_line(0)
end

---Evaluate current line
function Repl:eval_line()
  -- reset history position
  self.hist:reset_pos()

  local lines = self:get_line()
  -- ignore if it's only whitespace
  if not lines or util.lines_empty(lines) then
    return self:new_line()
  end

  -- save lines to history
  self.hist:append(lines)

  -- repl command
  local line = lines[1]
  if line:sub(1,1) == COMMAND_PREFIX then
    line = line:sub(2)
    local cmd, rest = line:match('^(%a*)%s*(.*)$')
    if not cmd then
      self:put(MSG_INVALID_COMMAND, 'neoreplError')
      return self:new_line()
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

    for _, c in ipairs(require('neorepl.cmd')) do
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
    return self:new_line()
  end

  if self.vim_mode then
    if self.vim:eval(lines) ~= false then
      return self:new_line()
    end
  else
    if self.lua:eval(lines) ~= false then
      return self:new_line()
    end
  end
end

---Execute function in current buffer/window context
function Repl:exec_context(f)
  local buf = self.buffer
  local win = self.window

  -- validate buffer and window
  local buf_valid = buf == 0 or api.nvim_buf_is_valid(buf)
  local win_valid = win == 0 or api.nvim_win_is_valid(win)
  if not buf_valid or not win_valid then
    local lines = {}
    if not buf_valid then
      self.buffer = 0
      table.insert(lines, 'buffer no longer valid, setting it back to 0')
    end
    if not win_valid then
      self.window = 0
      table.insert(lines, 'window no longer valid, setting it back to 0')
    end
    table.insert(lines, 'operation cancelled')
    self:put(lines, 'neoreplError')
    return false
  end

  if win > 0 then
    if buf > 0 then
      -- can buffer change here? maybe it's going to be easier to pcall all of this
      api.nvim_win_call(win, function()
        api.nvim_buf_call(buf, f)
      end)
    else
      api.nvim_win_call(win, f)
    end
  elseif buf > 0 then
    api.nvim_buf_call(buf, f)
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
      for _, c in ipairs(require('neorepl.cmd')) do
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
      results, start = self.vim:complete(line:sub(begin + 1))
    else
      begin = fn.match(line, [[\v\C^l%[ua]\s+\zs]])
      if begin < 0 then return end
      results, start = self.lua:complete(line:sub(begin + 1))
    end
    if start then
      start = start + begin + 1
    end

    if results and #results > 0 then
      return start or pos + 1, results
    end
    return
  end

  if self.vim_mode then
    start, results = self.vim:complete(line)
  else
    -- TODO: complete multiple lines
    start, results = self.lua:complete(line)
  end

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
  return Buf.goto_output(backward, to_end, count)
end

api.nvim_set_hl(0, 'neoreplError',     { default = true, link = 'ErrorMsg' })
api.nvim_set_hl(0, 'neoreplOutput',    { default = true, link = 'String' })
api.nvim_set_hl(0, 'neoreplValue',     { default = true, link = 'Number' })
api.nvim_set_hl(0, 'neoreplInfo',      { default = true, link = 'Function' })
api.nvim_set_hl(0, 'neoreplLinebreak', { default = true, link = 'Function' })

return Repl
