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

---@class nreplRepl
---@field bufnr       number    repl buffer
---@field buffer      number    buffer context
---@field vim_mode    boolean   vim mode
---@field mark_id     number    current mark id counter
---@field inspect     boolean   inspect variables
---@field indent      number    indent level
---@field indentstr?  string    indent string
---@field env         table     lua environment
---@field print       function  print function override
local M = {}
M.__index = M

--- Create a new REPL instance
---@param config? nreplConfig
function M.new(config)
  vim.cmd('enew')
  local bufnr = api.nvim_get_current_buf()
  api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  api.nvim_buf_set_option(bufnr, 'filetype', 'nrepl')
  api.nvim_buf_set_name(bufnr, 'nrepl('..bufnr..')')
  vim.cmd(string.format([=[
    inoremap <silent><buffer> <CR> <cmd>lua require'nrepl'.eval_line()<CR>
    inoremap <silent><buffer> <NL> <CR><C-U>\

    setlocal backspace=indent,start
    setlocal completeopt=menu
    inoremap <silent><buffer><expr> <Tab>
      \ pumvisible() ? '<C-N>' : '<cmd>lua require"nrepl".complete()<CR>'
    inoremap <buffer> <C-E> <C-E>
    inoremap <buffer> <C-Y> <C-Y>
    inoremap <buffer> <C-N> <C-N>
    inoremap <buffer> <C-P> <C-P>

    nnoremap <silent><buffer> [[ <cmd>lua require'nrepl'.goto_prev()<CR>
    nnoremap <silent><buffer> [] <cmd>lua require'nrepl'.goto_prev(true)<CR>
    nnoremap <silent><buffer> ]] <cmd>lua require'nrepl'.goto_next()<CR>
    nnoremap <silent><buffer> ][ <cmd>lua require'nrepl'.goto_next(true)<CR>

    syn match nreplLinebreak "^\\"

    augroup nrepl
      autocmd BufDelete <buffer> lua require'nrepl'[%d] = nil
    augroup end
  ]=], bufnr))

  ---@type nreplRepl
  local this = setmetatable({
    bufnr = bufnr,
    buffer = 0,
    vim_mode = config.lang == 'vim',
    mark_id = 1,
    inspect = config.inspect or false,
    indent = config.indent or 0,
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
---@param lines string[]
---@param hlgroup string
function M:put(lines, hlgroup)
  local s = api.nvim_buf_line_count(self.bufnr)
  if self.indentstr then
    local t = {}
    for i, line in ipairs(lines) do
      t[i] = self.indentstr..line
    end
    lines = t
  end
  api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)
  local e = api.nvim_buf_line_count(self.bufnr)
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

  -- repl command
  local cmd, args = line:match('^/%s*(%S*)%s*(.-)%s*$')
  if cmd then
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

    -- temporarily replace print
    if self.buffer > 0 then
      if not api.nvim_buf_is_valid(self.buffer) then
        self.buffer = 0
        self:put({'invalid buffer, setting it back to 0'}, 'nreplError')
        return
      end

      api.nvim_buf_call(self.buffer, function()
        _G.print = self.print
        ok, res, n = pcall_res(pcall(res))
        _G.print = prev_print
        vim.cmd('redraw') -- TODO: make this optional
      end)
    else
      _G.print = self.print
      ok, res, n = pcall_res(pcall(res))
      _G.print = prev_print
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

  if self.buffer > 0 then
    if not api.nvim_buf_is_valid(self.buffer) then
      self.buffer = 0
      self:put({'invalid buffer, setting it back to 0'}, 'nreplError')
      return
    end

    api.nvim_buf_call(self.buffer, function()
      ok, res = pcall(fn['nrepl#__evaluate__'], prg)
      vim.cmd('redraw') -- TODO: make this optional
    end)
  else
    ok, res = pcall(fn['nrepl#__evaluate__'], prg)
  end

  local hlgroup = ok and 'nreplOutput' or 'nreplError'
  self:put(vim.split(res, '\n', { plain = true, trimempty = true }), hlgroup)
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

  if self.buffer > 0 then
    if not api.nvim_buf_is_valid(self.buffer) then
      return
    end
    api.nvim_buf_call(self.buffer, function()
      completions = fn.getcompletion(line, comptype, 1)
    end)
  else
    completions = fn.getcompletion(line, comptype, 1)
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
