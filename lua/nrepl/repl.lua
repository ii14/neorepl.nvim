local api = vim.api
local fn = vim.fn
local nrepl = require('nrepl')

local ns = api.nvim_create_namespace('nrepl')

--- Reference to global environment
local global = _G
--- Reference to global print function
local prev_print = _G.print

local MSG_INVALID_COMMAND = {'invalid command'}

local BREAK_UNDO = api.nvim_replace_termcodes('<C-G>u', true, false, true)

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
---@field bufnr       number      repl buffer
---@field buffer      number      buffer context
---@field window      number      window context
---@field vim_mode    boolean     vim mode
---@field mark_id     number      current mark id counter
---@field redraw      boolean     redraw after evaluation
---@field inspect     boolean     inspect variables
---@field indent      number      indent level
---@field indentstr?  string      indent string
---@field history     string[]    command history
---@field histpos     number      position in history
---@field histcur     string|nil  line before moving through history
---@field env         table       lua environment
---@field print       function    print function override
local M = {}
M.__index = M

--- Create a new REPL instance
---@param config? nreplConfig
function M.new(config)
  if config.buffer then
    config.buffer = require('nrepl.util').parse_buffer(config.buffer, true)
    if not config.buffer then
      error('invalid buffer')
    end
  end
  if config.window then
    config.window = require('nrepl.util').parse_window(config.window, true)
    if not config.window then
      error('invalid window')
    end
  end

  vim.cmd('enew')
  local bufnr = api.nvim_get_current_buf()
  api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  api.nvim_buf_set_option(bufnr, 'filetype', 'nrepl')
  api.nvim_buf_set_name(bufnr, 'nrepl('..bufnr..')')
  vim.cmd(string.format([=[
    imap <silent><buffer> <CR> <Plug>(nrepl-eval-line)
    imap <silent><buffer> <NL> <Plug>(nrepl-break-line)

    setlocal backspace=indent,start
    setlocal completeopt=menu
    imap <silent><buffer><expr> <Tab> pumvisible() ? '<C-N>' : '<Plug>(nrepl-complete)'
    imap <silent><buffer><expr> <C-P> pumvisible() ? '<C-P>' : '<Plug>(nrepl-hist-prev)'
    imap <silent><buffer><expr> <C-N> pumvisible() ? '<C-N>' : '<Plug>(nrepl-hist-next)'
    imap <silent><buffer> <Up>   <Plug>(nrepl-hist-prev)
    imap <silent><buffer> <Down> <Plug>(nrepl-hist-next)
    inoremap <buffer> <C-E> <C-E>
    inoremap <buffer> <C-Y> <C-Y>

    nmap <silent><buffer> [[ <Plug>(nrepl-[[)
    nmap <silent><buffer> [] <Plug>(nrepl-[])
    nmap <silent><buffer> ]] <Plug>(nrepl-]])
    nmap <silent><buffer> ][ <Plug>(nrepl-][)

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
    inspect = get_opt(config.inspect, false),
    indent = get_opt(config.indent, 0),
    history = {},
    histpos = 0,
    mark_id = 1,
  }, M)

  if this.indent > 0 then
    this.indentstr = string.rep(' ', this.indent)
  end

  this.print = function(...)
    local args = {...}
    for i, v in ipairs(args) do
      args[i] = tostring(v)
    end
    local lines = vim.split(table.concat(args, '\t'), '\n', { plain = true })
    this:put(lines, 'nreplOutput')
  end

  this.env = setmetatable({
    --- access to global environment
    global = global,
    --- print function override
    print = this.print,
  }, {
    __index = function(t, key)
      return rawget(t, key) or rawget(global, key)
    end,
  })

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

local COMMANDS = nil

function M:new_line()
  api.nvim_buf_set_lines(self.bufnr, -1, -1, false, {''})
  vim.cmd('$') -- TODO: don't use things like this, buffer can change during evaluation

  -- break undo sequence
  local mode = api.nvim_get_mode().mode
  if mode == 'i' or mode == 'ic' or mode == 'ix' then
    api.nvim_feedkeys(BREAK_UNDO, 'n', true)
  end
end

--- Evaluate current line
function M:eval_line()
  local line = api.nvim_get_current_line()
  if line:match('^%s*$') then
    return self:new_line()
  end

  self.histpos = 0
  -- remove duplicate entries
  for i = #self.history, 1, -1 do
    if self.history[i] == line then
      table.remove(self.history, i)
    end
  end
  -- TODO: save multiple lines
  table.insert(self.history, line)

  -- repl command
  if line:sub(1,1) == '/' then
    local cmd, args = line:match('^/(%a*)%s*(.-)%s*$')
    if not cmd then
      self:put(MSG_INVALID_COMMAND, 'nreplError')
      return self:new_line()
    end

    if args == '' then
      args = nil
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

  -- line breaks
  if line:match('^\\') then
    -- TODO: look ahead for line breaks too?
    -- the problem with that is that the evaluation
    -- output could potentially contain backslashes.
    local lnum = api.nvim_win_get_cursor(0)[1]
    local prg = { line:sub(2) }
    while true do
      lnum = lnum - 1
      if lnum <= 0 then
        self:put({'invalid line break'}, 'nreplError')
        return self:new_line()
      end

      line = api.nvim_buf_get_lines(self.bufnr, lnum - 1, lnum, true)[1]
      if not line:match('^\\') then
        if line:match('^/') then
          self:put({'line breaks not implemented for repl commands'}, 'nreplError')
          return self:new_line()
        end

        table.insert(prg, 1, line)
        if self.vim_mode then
          self:eval_vim(table.concat(prg, '\n'):gsub('\n%s*\\', ' '))
        else
          self:eval_lua(table.concat(prg, '\n'))
        end
        return self:new_line()
      else
        table.insert(prg, 1, line:sub(2))
      end
    end
  end

  if self.vim_mode then
    self:eval_vim(line)
  else
    self:eval_lua(line)
  end
  return self:new_line()
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

--- Evaluate lua and append output to the buffer
---@param prg string
function M:eval_lua(prg)
  local ok, res, err, n
  res = loadstring('return '..prg, 'nrepl')
  if not res then
    res, err = loadstring(prg, 'nrepl')
  end

  if res then
    setfenv(res, self.env)

    if not self:exec_context(function()
      -- temporarily replace print
      _G.print = self.print
      ok, res, n = pcall_res(pcall(res))
      _G.print = prev_print
      if self.redraw then
        vim.cmd('redraw')
      end
    end) then
      return
    end

    if not ok then
      local msg = res:gsub([[^%[string "nrepl"%]:%d+:%s*]], '', 1)
      self:put({msg}, 'nreplError')
    else
      if self.inspect then
        for i = 1, n do
          res[i] = vim.inspect(res[i])
        end
      else
        for i = 1, n do
          res[i] = tostring(res[i])
        end
      end
      if #res > 0 then
        self:put(vim.split(table.concat(res, ', '), '\n', { plain = true }), 'nreplValue')
      end
    end
  else
    local msg = err:gsub([[^%[string "nrepl"%]:%d+:%s*]], '', 1)
    self:put({msg}, 'nreplError')
  end
end

--- Evaluate vim script and append output to the buffer
---@param prg string
function M:eval_vim(prg)
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

  local hlgroup = ok and 'nreplOutput' or 'nreplError'
  self:put(vim.split(res, '\n', { plain = true, trimempty = true }), hlgroup)
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

function M:hist_prev()
  if #self.history == 0 then
    return
  elseif self.histpos == 0 then
    self.histcur = api.nvim_get_current_line()
  end
  self.histpos = self.histpos + 1
  if self.histpos > #self.history then
    self.histpos = 0
    api.nvim_set_current_line(self.histcur)
  else
    api.nvim_set_current_line(self.history[#self.history - self.histpos + 1])
  end
end

function M:hist_next()
  if #self.history == 0 then
    return
  elseif self.histpos == 0 then
    self.histcur = api.nvim_get_current_line()
  end
  self.histpos = self.histpos - 1
  if self.histpos == 0 then
    api.nvim_set_current_line(self.histcur)
  elseif self.histpos < 0 then
    self.histpos = #self.history
    print(1)
    api.nvim_set_current_line(self.history[1])
  else
    api.nvim_set_current_line(self.history[#self.history - self.histpos + 1])
  end
end

function M:complete()
  local line = api.nvim_get_current_line()
  local pos = api.nvim_win_get_cursor(0)[2]
  line = line:sub(1, pos)
  local completions, start, comptype

  if line:sub(1,1) == '/' then
    -- TODO: complete command arguments too
    if not line:match('^/%S*$') then
      return
    end

    local candidates = {}
    local word = line:sub(2)
    local size = #word
    for _, c in ipairs(COMMANDS or require('nrepl.commands')) do
      if word == c.command:sub(1, size) then
        table.insert(candidates, c.command)
      end
    end
    if #candidates > 0 then
      fn.complete(2, candidates)
    end
    return
  elseif self.vim_mode then
    start = line:find('%S+$')
    comptype = 'cmdline'
  else
    -- TODO: completes with the global lua environment, instead of repl env
    start = line:find('[%a_][%w_]*$')
    comptype = 'lua'
  end

  if not self:exec_context(function()
    completions = fn.getcompletion(line, comptype, 1)
  end) then
    return
  end

  if completions and #completions > 0 then
    fn.complete(start or pos + 1, completions)
  end
end

--- Go to previous/next output implementation
---@param backward boolean
---@param to_end? boolean
function M:goto_output(backward, to_end)
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
        api.nvim_win_set_cursor(0, { range[1], 0 })
      elseif not backward and to_end and lnum < range[2] then
        api.nvim_win_set_cursor(0, { range[2], 0 })
      else
        if backward then
          range = ranges[i - 1]
        else
          range = ranges[i + 1]
        end
        if range then
          api.nvim_win_set_cursor(0, { (to_end and range[2] or range[1]), 0 })
        end
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
