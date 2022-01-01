local api = vim.api
local fn = vim.fn
local nrepl = require('nrepl')

local ns = api.nvim_create_namespace('nrepl')

--- Reference to global environment
local global = _G
--- Reference to global print function
local prev_print = _G.print

local M = {}

local MSG_VIM = {'-- VIMSCRIPT --'}
local MSG_LUA = {'-- LUA --'}
local MSG_INVALID_COMMAND = {'invalid command'}
local MSG_ARGS_NOT_ALLOWED = {'arguments not allowed for this command'}
local MSG_INVALID_ARGS = {'invalid argument'}
local MSG_INVALID_BUF = {'invalid buffer'}
local MSG_HELP = {
  '/lua EXPR    - switch to lua or evaluate expression',
  '/vim EXPR    - switch to vimscript or evaluate expression',
  '/buffer B    - change buffer context (0 to disable) or print current value',
  '/window N    - NOT IMPLEMENTED: change window context',
  '/indent N    - set indentation or print current value',
  '/clear       - clear buffer',
  '/quit        - close repl instance',
}

local BUF_EMPTY = '[No Name]'
local BREAK_UNDO = api.nvim_replace_termcodes('<C-G>u', true, false, true)

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

--- Create a new REPL instance
---@param config? nreplConfig
function M.new(config)
  config = nrepl._normalize_config(vim.tbl_extend('force', nrepl._default_config, config or {}))

  vim.cmd('enew')
  local bufnr = api.nvim_get_current_buf()
  api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  api.nvim_buf_set_option(bufnr, 'filetype', 'nrepl')
  api.nvim_buf_set_name(bufnr, 'nrepl('..bufnr..')')
  vim.cmd(string.format([=[
    inoremap <silent><buffer> <CR> <cmd>lua require'nrepl'.eval_line()<CR>

    setlocal completeopt=menu
    inoremap <silent><buffer><expr> <Tab>
      \ pumvisible() ? '<C-N>' : '<cmd>lua require"nrepl".get_completion()<CR>'
    inoremap <buffer> <C-E> <C-E>
    inoremap <buffer> <C-Y> <C-Y>
    inoremap <buffer> <C-N> <C-N>
    inoremap <buffer> <C-P> <C-P>

    nnoremap <silent><buffer> [[ <cmd>lua require'nrepl'.goto_prev()<CR>
    nnoremap <silent><buffer> [] <cmd>lua require'nrepl'.goto_prev(true)<CR>
    nnoremap <silent><buffer> ]] <cmd>lua require'nrepl'.goto_next()<CR>
    nnoremap <silent><buffer> ][ <cmd>lua require'nrepl'.goto_next(true)<CR>

    augroup nrepl
      autocmd BufDelete <buffer> lua require'nrepl'[%d] = nil
    augroup end
  ]=], bufnr))

  local mark_id = 1
  local indentstr
  local indent = config.indent or 0
  if indent and indent > 0 then
    indentstr = string.rep(' ', indent)
  end

  local this = {
    bufnr = bufnr,
    buffer = 0,
    vim_mode = config.lang == 'vim',
  }

  --- Append lines to the buffer
  ---@param lines string[]
  ---@param hlgroup string
  local function put(lines, hlgroup)
    local s = api.nvim_buf_line_count(bufnr)
    if indentstr then
      local t = {}
      for i, line in ipairs(lines) do
        t[i] = indentstr..line
      end
      lines = t
    end
    api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
    local e = api.nvim_buf_line_count(bufnr)
    if s ~= e then
      mark_id = mark_id + 1
      api.nvim_buf_set_extmark(bufnr, ns, s, 0, {
        id = mark_id,
        end_line = e,
        hl_group = hlgroup,
        hl_eol = true,
      })
    end
  end

  local env = {
    -- access to global environment
    global = global,
  }
  setmetatable(env, {
    __index = function(t, key)
      return rawget(t, key) or rawget(global, key)
    end,
  })

  --- print function override
  function env.print(...)
    local args = {...}
    for i, v in ipairs(args) do
      args[i] = tostring(v)
    end
    local lines = vim.split(table.concat(args, '\t'), '\n', { plain = true })
    put(lines, 'nreplOutput')
  end

  --- Evaluate lua and append output to the buffer
  ---@param prg string
  local function lua_eval(prg)
    local ok, res, err, n
    res = loadstring('return '..prg, 'nrepl')
    if not res then
      res, err = loadstring(prg, 'nrepl')
    end

    if res then
      setfenv(res, env)

      -- temporarily replace print
      if this.buffer > 0 then
        if not api.nvim_buf_is_valid(this.buffer) then
          this.buffer = 0
          put({'invalid buffer, setting it back to 0'}, 'nreplError')
          return
        end

        api.nvim_buf_call(this.buffer, function()
          _G.print = env.print
          ok, res, n = pcall_res(pcall(res))
          _G.print = prev_print
          vim.cmd('redraw') -- TODO: make this optional
        end)
      else
        _G.print = env.print
        ok, res, n = pcall_res(pcall(res))
        _G.print = prev_print
      end

      if not ok then
        local msg = res:gsub([[^%[string "nrepl"%]:%d+:%s*]], '', 1)
        put({msg}, 'nreplError')
      else
        for i = 1, n do
          res[i] = tostring(res[i])
        end
        if #res > 0 then
          put(vim.split(table.concat(res, ', '), '\n', { plain = true }), 'nreplValue')
        end
      end
    else
      local msg = err:gsub([[^%[string "nrepl"%]:%d+:%s*]], '', 1)
      put({msg}, 'nreplError')
    end
  end

  --- Evaluate vim script and append output to the buffer
  ---@param prg string
  local function vim_eval(prg)
    -- call execute() from a vim script file to have script local variables.
    -- context is shared between repl instances. a potential solution is to
    -- create a temporary script for each instance.
    local ok, res

    if this.buffer > 0 then
      if not api.nvim_buf_is_valid(this.buffer) then
        this.buffer = 0
        put({'invalid buffer, setting it back to 0'}, 'nreplError')
        return
      end

      api.nvim_buf_call(this.buffer, function()
        ok, res = pcall(fn['nrepl#__evaluate__'], prg)
        vim.cmd('redraw') -- TODO: make this optional
      end)
    else
      ok, res = pcall(fn['nrepl#__evaluate__'], prg)
    end

    if ok then
      put(vim.split(res, '\n', { plain = true, trimempty = true }), 'nreplOutput')
    else
      put({res}, 'nreplError')
    end
  end

  --- Evaluate current line
  function this.eval_line()
    local line = api.nvim_get_current_line()
    local cmd, args = line:match('^/%s*(%S*)%s*(.-)%s*$')
    if cmd then
      if args == '' then
        args = nil
      end
      if fn.match(cmd, [=[\v\C^q%[uit]$]=]) >= 0 then
        if args then
          put(MSG_ARGS_NOT_ALLOWED, 'nreplError')
        else
          nrepl.close(bufnr)
          return
        end
      elseif fn.match(cmd, [=[\v\C^c%[lear]$]=]) >= 0 then
        if args then
          put(MSG_ARGS_NOT_ALLOWED, 'nreplError')
        else
          api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
          api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
          return
        end
      elseif fn.match(cmd, [=[\v\C^h%[elp]$]=]) >= 0 then
        if args then
          put(MSG_ARGS_NOT_ALLOWED, 'nreplError')
        else
          put(MSG_HELP, 'nreplInfo')
        end
      elseif fn.match(cmd, [=[\v\C^l%[ua]$]=]) >= 0 then
        if args then
          lua_eval(args)
        else
          this.vim_mode = false
          put(MSG_LUA, 'nreplInfo')
        end
      elseif fn.match(cmd, [=[\v\C^v%[im]$]=]) >= 0 then
        if args then
          vim_eval(args)
        else
          this.vim_mode = true
          put(MSG_VIM, 'nreplInfo')
        end
      elseif fn.match(cmd, [=[\v\C^b%[uffer]$]=]) >= 0 then
        if args then
          local num = args:match('^%d+$')
          if num then args = tonumber(num) end
          if args == 0 then
            this.buffer = 0
            put({'buffer: none'}, 'nreplInfo')
          else
            local value = fn.bufnr(args)
            if value >= 0 then
              this.buffer = value
              local bufname = fn.bufname(this.buffer)
              if bufname == '' then
                bufname = BUF_EMPTY
              end
              put({'buffer: '..this.buffer..' '..bufname}, 'nreplInfo')
            else
              put(MSG_INVALID_BUF, 'nreplError')
            end
          end
        else
          if this.buffer > 0 then
            if fn.bufnr(this.buffer) >= 0 then
              local bufname = fn.bufname(this.buffer)
              if bufname == '' then
                bufname = BUF_EMPTY
              end
              put({'buffer: '..this.buffer..' '..bufname}, 'nreplInfo')
            else
              put({'buffer: '..this.buffer..' [invalid]'}, 'nreplInfo')
            end
          else
            put({'buffer: none'}, 'nreplInfo')
          end
        end
      elseif fn.match(cmd, [=[\v\C^i%[ndent]$]=]) >= 0 then
        if args then
          local value = args:match('^%d+$')
          if value then
            value = tonumber(value)
            if value < 0 or value > 32 then
              put(MSG_INVALID_ARGS, 'nreplError')
            elseif value == 0 then
              indent = 0
              indentstr = nil
              put({'indent: '..indent}, 'nreplInfo')
            else
              indent = value
              indentstr = string.rep(' ', value)
              put({'indent: '..indent}, 'nreplInfo')
            end
          else
            put(MSG_INVALID_ARGS, 'nreplError')
          end
        else
          put({'indent: '..indent}, 'nreplInfo')
        end
      else
        put(MSG_INVALID_COMMAND, 'nreplError')
      end
    else
      if this.vim_mode then
        vim_eval(line)
      else
        lua_eval(line)
      end
    end

    api.nvim_buf_set_lines(bufnr, -1, -1, false, {''})
    vim.cmd('$') -- TODO: don't use things like this, buffer can change during evaluation

    -- break undo sequence
    local mode = api.nvim_get_mode().mode
    if mode == 'i' or mode == 'ic' or mode == 'ix' then
      api.nvim_feedkeys(BREAK_UNDO, 'n', true)
    end
  end

  nrepl[bufnr] = this
  if config.on_init then
    config.on_init(bufnr)
  end
  if config.startinsert then
    vim.cmd('startinsert')
  end
end

vim.cmd([[
  hi link nreplError  ErrorMsg
  hi link nreplOutput String
  hi link nreplValue  Number
  hi link nreplInfo   Function
]])

return M
