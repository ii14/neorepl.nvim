local api = vim.api
local fn = vim.fn
local nrepl = require('nrepl')
local util = require('nrepl.util')

local ns = api.nvim_create_namespace('nrepl')

--- Reference to global environment
local global = _G
--- Reference to global print function
local prev_print = _G.print

local COMMAND_PREFIX = '/'

local MSG_INVALID_COMMAND = {'invalid command'}

local BREAK_UNDO = api.nvim_replace_termcodes('<C-G>u', true, false, true)

local luacomplete = nil

---@type nreplCommand[]
local COMMANDS = nil

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

---@class nreplRepl
---@field bufnr       number        repl buffer
---@field buffer      number        buffer context
---@field window      number        window context
---@field vim_mode    boolean       vim mode
---@field mark_id     number        current mark id counter
---@field redraw      boolean       redraw after evaluation
---@field inspect     boolean       inspect variables
---@field indent      number        indent level
---@field indentstr?  string        indent string
---@field history     string[][]    command history
---@field histpos     number        position in history
---@field histcur     string[]|nil  line before moving through history
---@field luaenv      table         lua environment
---@field luaprint    function      print function override
local M = {}
M.__index = M

--- Create a new REPL instance
---@param config? nreplConfig
function M.new(config)
  if config.buffer then
    config.buffer = util.parse_buffer(config.buffer, true)
    if not config.buffer then
      error('invalid buffer')
    end
  end
  if config.window then
    config.window = util.parse_window(config.window, true)
    if not config.window then
      error('invalid window')
    end
  end

  vim.cmd('enew')
  local bufnr = api.nvim_get_current_buf()
  api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  api.nvim_buf_set_name(bufnr, 'nrepl('..bufnr..')')
  if config.no_defaults ~= true then
    vim.cmd(string.format([=[
      imap <silent><buffer> <CR> <Plug>(nrepl-eval-line)
      imap <silent><buffer> <NL> <Plug>(nrepl-break-line)

      setlocal backspace=indent,start
      setlocal completeopt=menu
      imap <silent><buffer><expr> <Tab> pumvisible() ? '<C-N>' : '<Plug>(nrepl-complete)'
      imap <silent><buffer><expr> <C-P> pumvisible() ? '<C-P>' : '<Plug>(nrepl-hist-prev)'
      imap <silent><buffer><expr> <C-N> pumvisible() ? '<C-N>' : '<Plug>(nrepl-hist-next)'
      inoremap <expr><buffer> <C-E> pumvisible() ? '<C-E>' : '<End>'
      inoremap       <buffer> <C-Y> <C-Y>
      inoremap       <buffer> <C-A> <Home>

      nmap <silent><buffer> [[ <Plug>(nrepl-[[)
      nmap <silent><buffer> [] <Plug>(nrepl-[])
      nmap <silent><buffer> ]] <Plug>(nrepl-]])
      nmap <silent><buffer> ][ <Plug>(nrepl-][)
    ]=]))
  end
  -- set filetype after mappings and settings to allow overriding in ftplugin
  api.nvim_buf_set_option(bufnr, 'filetype', 'nrepl')
  vim.cmd(string.format([=[
    syn match nreplLinebreak "^\\"
    augroup nrepl
      autocmd BufDelete <buffer> lua require'nrepl'[%d] = nil
    augroup end
  ]=], bufnr))

  ---@type nreplRepl
  local this = setmetatable({
    bufnr = bufnr,
    buffer = config.buffer or 0,
    window = config.window or 0,
    vim_mode = config.lang == 'vim',
    redraw = get_opt(config.redraw, true),
    inspect = get_opt(config.inspect, true),
    indent = get_opt(config.indent, 0),
    history = {},
    histpos = 0,
    mark_id = 1,
  }, M)

  if this.indent > 0 then
    this.indentstr = string.rep(' ', this.indent)
  end

  this.luaprint = function(...)
    local args = {...}
    for i, v in ipairs(args) do
      args[i] = tostring(v)
    end
    local lines = vim.split(table.concat(args, '\t'), '\n', { plain = true })
    this:put(lines, 'nreplOutput')
  end

  this.luaenv = setmetatable({
    --- access to global environment
    global = global,
    --- print function override
    print = this.luaprint,
  }, {
    __index = function(t, key)
      return rawget(t, key) or rawget(global, key)
    end,
  })

  -- add user environment
  local userenv = config.env_lua
  if userenv then
    (function()
      if type(userenv) == 'function' then
        local ok, res = pcall(userenv)
        if not ok then
          local err = vim.split(res, '\n', { plain = true })
          table.insert(err, 1, 'Error from user env:')
          this:put(err, 'nreplError')
          return this:new_line()
        elseif type(res) == nil then
          return
        elseif type(res) ~= 'table' then
          this:put({'Result of user env is not a table'}, 'nreplError')
          return this:new_line()
        else
          userenv = res
        end
      end

      for k, v in pairs(userenv) do
        this.luaenv[k] = v
      end
    end)()
  end

  nrepl[bufnr] = this
  if config.on_init then
    config.on_init(bufnr)
  end
  if config.startinsert then
    vim.cmd('startinsert')
  end
end

--- Append lines to the buffer
---@param lines string[]  lines
---@param hlgroup string  highlight group
function M:put(lines, hlgroup)
  -- indent lines
  if self.indentstr then
    local t = {}
    for i, line in ipairs(lines) do
      t[i] = self.indentstr..line
    end
    lines = t
  end

  local s = api.nvim_buf_line_count(self.bufnr)
  api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)
  local e = api.nvim_buf_line_count(self.bufnr)

  -- highlight
  if s ~= e then
    self.mark_id = self.mark_id + 1
    api.nvim_buf_set_extmark(self.bufnr, ns, s, 0, {
      id = self.mark_id,
      end_line = e,
      hl_group = hlgroup,
      hl_eol = true,
    })
  end
end

function M:clear()
  self.mark_id = 1
  api.nvim_buf_clear_namespace(self.bufnr, ns, 0, -1)
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, {})
end

--- Append empty line
function M:new_line()
  api.nvim_buf_set_lines(self.bufnr, -1, -1, false, {''})
  vim.cmd('$') -- TODO: don't use things like this, buffer can change during evaluation

  -- break undo sequence
  local mode = api.nvim_get_mode().mode
  if mode == 'i' or mode == 'ic' or mode == 'ix' then
    api.nvim_feedkeys(BREAK_UNDO, 'n', true)
  end
end

--- Get lines under cursor
--- Returns nil on illegal line break
---@return string[]|nil
function M:get_line()
  local line = api.nvim_get_current_line()
  local lnum = api.nvim_win_get_cursor(0)[1]
  local s, e = lnum, lnum
  local lines = {line}

  if line:sub(1,1) == '\\' then
    for i = lnum - 1, 1, -1 do
      line = api.nvim_buf_get_lines(self.bufnr, i - 1, i, true)[1]
      table.insert(lines, 1, line)
      if line:sub(1,1) ~= '\\' then
        s = i
        break
      end
    end
    if lines[1]:sub(1,1) == '\\' then
      return nil -- illegal line break
    end
  end

  local max = api.nvim_buf_line_count(self.bufnr)
  while e < max do
    e = e + 1
    line = api.nvim_buf_get_lines(self.bufnr, e - 1, e, true)[1]
    if line:sub(1,1) == '\\' then
      table.insert(lines, line)
    else
      break
    end
  end

  return lines, s, e
end

--- Evaluate current line
function M:eval_line()
  -- reset history position
  self.histpos = 0

  local lines = self:get_line()
  if lines == nil then
    self:put({'illegal line break'}, 'nreplError')
    return self:new_line()
  end

  -- ignore if it's only whitespace
  if util.lines_empty(lines) then
    return self:new_line()
  end

  -- remove duplicate entries in history
  for i = #self.history, 1, -1 do
    if util.lines_equal(self.history[i], lines) then
      table.remove(self.history, i)
    end
  end
  -- save lines to history
  table.insert(self.history, lines)

  -- repl command
  local line = lines[1]
  if line:sub(1,1) == COMMAND_PREFIX then
    line = line:sub(2)
    local cmd, rest = line:match('^(%a*)%s*(.*)$')
    if not cmd then
      self:put(MSG_INVALID_COMMAND, 'nreplError')
      return self:new_line()
    end

    -- copy lines, trim command and line breaks
    local args = {rest}
    for i = 2, #lines do
      args[i] = lines[i]:sub(2)
    end

    if util.lines_empty(args) then
      args = nil
    elseif #args == 1 then
      -- trim trailing whitespace
      args[1] = args[1]:match('^(.-)%s*$')
    end

    for _, c in ipairs(COMMANDS or require('nrepl.commands')) do
      if c.pattern == nil then
        local name = c.command
        c.pattern = '\\v\\C^'..name:sub(1,1)..'%['..name:sub(2)..']$'
      end

      if fn.match(cmd, c.pattern) >= 0 then
        -- don't append new line when command returns false
        if c.run(args, self) ~= false then
          self:new_line()
        end
        return
      end
    end

    self:put(MSG_INVALID_COMMAND, 'nreplError')
    return self:new_line()
  end

  -- strip leading backslashes
  local prg = {}
  prg[1] = lines[1]
  for i = 2, #lines do
    prg[i] = lines[i]:sub(2)
  end

  if self.vim_mode then
    if self:eval_vim(prg) ~= false then
      return self:new_line()
    end
  else
    if self:eval_lua(prg) ~= false then
      return self:new_line()
    end
  end
end

--- Gather results from pcall
local function pcall_res(ok, ...)
  if ok then
    -- return returned values as a table and its size,
    -- because when iterating ipairs will stop at nil
    return ok, {...}, select('#', ...)
  else
    return ok, ...
  end
end

local function lua_exec(f)
  local coro = coroutine.create(f)
  local ok, res, n = pcall_res(coroutine.resume(coro))
  if not ok then
    if debug.getinfo(coro, 0, 'f').func ~= f then
      res = debug.traceback(coro, res, 0)
    end
  end
  return ok, res, n
end

--- Evaluate lua and append output to the buffer
---@param prg string
function M:eval_lua(prg)
  if type(prg) == 'table' then
    prg = table.concat(prg, '\n')
  elseif type(prg) ~= 'string' then
    error('invalid prg type')
  end

  local ok, res, err, n
  res = loadstring('return '..prg, 'nrepl')
  if not res then
    res, err = loadstring(prg, 'nrepl')
  end

  if res then
    setfenv(res, self.luaenv)

    if not self:exec_context(function()
      -- temporarily replace print
      _G.print = self.luaprint
      ok, res, n = lua_exec(res)
      _G.print = prev_print
      if self.redraw then
        vim.cmd('redraw')
      end
    end) then
      return
    end

    if not ok then
      self:put(vim.split(res, '\n', { plain = true }), 'nreplError')
    else
      local stringify = self.inspect and vim.inspect or tostring
      for i = 1, n do
        res[i] = stringify(res[i])
      end
      if #res > 0 then
        self:put(vim.split(table.concat(res, ', '), '\n', { plain = true }), 'nreplValue')
      end
    end
  elseif err:match("'<eof>'$") then
    -- more input expected, add line break
    api.nvim_buf_set_lines(self.bufnr, -1, -1, false, {'\\'})
    vim.cmd('$')
    return false
  else
    self:put({err}, 'nreplError')
  end
end

--- Evaluate vim script and append output to the buffer
---@param prg string
function M:eval_vim(prg)
  if type(prg) == 'table' then
    prg = table.concat(prg, '\n'):gsub('\n%s*\\', ' ')
  elseif type(prg) ~= 'string' then
    error('invalid prg type')
  end

  -- print variables
  if prg:match('^%s*[bgstvw%(]:%s*$') then
    -- use let for plain g:, b:, w:, ...
    prg = 'let '..prg
  elseif prg:match('^%s*[bgstvw%(]:') or prg:match('^%s*%(') then
    prg = 'echo '..prg
  end

  -- call execute() from a vim script file to have script local variables.
  -- context is shared between repl instances. a potential solution is to
  -- create a temporary script for each instance.
  local ok, res
  if not self:exec_context(function()
    ok, res = pcall(fn['nrepl#__evaluate__'], prg)
    if self.redraw then
      vim.cmd('redraw')
    end
  end) then
    return
  end

  if ok then
    local hlgroup
    if type(res) == 'table' then
      hlgroup = 'nreplError'
      local throwpoint = res.throwpoint
      res = vim.split(res.exception, '\n', { plain = true, trimempty = true })
      table.insert(res, 1, 'Error detected while processing '..throwpoint..':')
    else
      hlgroup = 'nreplOutput'
      res = vim.split(res, '\n', { plain = true, trimempty = true })
    end
    self:put(res, hlgroup)
  else
    self:put(vim.split(res, '\n', { plain = true, trimempty = true }), 'nreplError')
  end
end

--- Execute function in current buffer/window context
function M:exec_context(f)
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
    self:put(lines, 'nreplError')
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

--- Move between entries in history
---@param prev boolean previous entry if true, next entry if false
function M:hist_move(prev)
  if #self.history == 0 then return end
  local lines, s, e = self:get_line()
  if lines == nil then return end
  if self.histpos == 0 then
    self.histcur = lines
  end

  local nlines
  if prev then
    self.histpos = self.histpos + 1
    if self.histpos > #self.history then
      self.histpos = 0
      nlines = self.histcur
    else
      nlines = self.history[#self.history - self.histpos + 1]
    end
  else
    self.histpos = self.histpos - 1
    if self.histpos == 0 then
      nlines = self.histcur
    elseif self.histpos < 0 then
      self.histpos = #self.history
      nlines = self.history[1]
    else
      nlines = self.history[#self.history - self.histpos + 1]
    end
  end

  api.nvim_buf_set_lines(self.bufnr, s - 1, e, true, nlines)
  api.nvim_win_set_cursor(0, { s + #nlines - 1, #nlines[#nlines] })
end

--- Complete word under cursor
function M:complete()
  local line = api.nvim_get_current_line()
  local pos = api.nvim_win_get_cursor(0)[2]
  line = line:sub(1, pos)
  local completions, start

  if line:sub(1,1) == COMMAND_PREFIX then
    line = line:sub(2)
    -- TODO: complete command arguments too
    if not line:match('^%S*$') then
      return
    end

    local candidates = {}
    local size = #line
    for _, c in ipairs(COMMANDS or require('nrepl.commands')) do
      if line == c.command:sub(1, size) then
        table.insert(candidates, c.command)
      end
    end
    if #candidates > 0 then
      fn.complete(2, candidates)
    end
    return
  elseif self.vim_mode then
    start = line:find('[^%s%(%)=%-%+%*|/~%.,]*$')
    if line:match('^%s*[bgstvw]:') or line:match('^%s*%(') then
      line = 'echo '..line
    end

    if not self:exec_context(function()
      completions = fn.getcompletion(line, 'cmdline', 1)
    end) then
      return
    end
  else
    if luacomplete == nil then
      luacomplete = require('nrepl.lua.parser').complete
    end

    -- TODO: concat with previous lines
    completions, start = luacomplete(line)
    if completions == nil then
      return
    end
    start = start + 1
  end

  if completions and #completions > 0 then
    fn.complete(start or pos + 1, completions)
  end
end

--- Go to previous/next output implementation
---@param backward boolean
---@param to_end? boolean
function M:goto_output(backward, to_end, count)
  count = count or 1
  local ranges = {}
  do
    local lnum = 1
    -- TODO: do I have to sort them?
    for _, m in ipairs(api.nvim_buf_get_extmarks(self.bufnr, ns, 0, -1, { details = true })) do
      local s = m[2] + 1
      local e = m[4].end_row
      if e >= s then
        -- insert ranges between extmarks
        if s > lnum then
          table.insert(ranges, { lnum, s - 1 })
        end
        table.insert(ranges, { s, e })
        lnum = e + 1
      end
    end
    -- insert last range
    local last = api.nvim_buf_line_count(self.bufnr)
    if last >= lnum then
      table.insert(ranges, { lnum, last })
    end
  end

  local lnum = api.nvim_win_get_cursor(0)[1]
  for i, range in ipairs(ranges) do
    if lnum >= range[1] and lnum <= range[2] then
      if backward and not to_end and lnum > range[1] then
        if count == 1 then
          api.nvim_win_set_cursor(0, { range[1], 0 })
          return
        else
          count = count - 1
        end
      elseif not backward and to_end and lnum < range[2] then
        if count == 1 then
          api.nvim_win_set_cursor(0, { range[2], 0 })
          return
        else
          count = count - 1
        end
      end

      if backward then
        count = -count
      end

      local idx = i + count
      if idx > #ranges then
        idx = #ranges
      elseif idx < 1 then
        idx = 1
      end
      range = ranges[idx]
      if range then
        api.nvim_win_set_cursor(0, { (to_end and range[2] or range[1]), 0 })
      end
      return
    end
  end
end

vim.cmd([[
  hi link nreplError      ErrorMsg
  hi link nreplOutput     String
  hi link nreplValue      Number
  hi link nreplInfo       Function
  hi link nreplLinebreak  Function
]])

return M
