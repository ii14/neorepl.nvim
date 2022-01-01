local api = vim.api
local fn = vim.fn

local ns = api.nvim_create_namespace('nrepl')

--- Reference to global environment
local global = _G
--- Reference to global print function
local prev_print = _G.print

local M = {}

local HELP = {
  '/lua     - enter lua mode',
  '/vim     - enter vimscript mode',
  '/clear   - clear buffer',
  '/quit    - close repl instance',
  '/buffer  - not implemented: change buffer context',
  '/window  - not implemented: change window context',
  '/tabpage - not implemented: change tabpage context',
}

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

---@class nreplConfig
---@field lang? 'lua'|'vim'
---@field on_init? function(bufnr: number)

--- Normalize configuration
---@param config? nreplConfig
local function normalize_config(config)
  local c = config and vim.deepcopy(config) or {}
  if c.lang == '' then
    c.lang = nil
  end
  if c.lang ~= nil and c.lang ~= 'lua' and c.lang ~= 'vim' then
    error('invalid lang value, expected "lua", "vim" or nil')
  end
  if c.on_init ~= nil and type(c.on_init) ~= 'function' then
    error('invalid on_init value, expected function or nil')
  end
  return c
end

---@type nreplConfig Default configuration
local default_config = {}

--- Set default configuration
---@param config? nreplConfig
function M.config(config)
  M.default_config = normalize_config(config)
end

--- Create a new REPL instance
---@param config? nreplConfig
function M.new(config)
  config = normalize_config(vim.tbl_extend('force', default_config, config or {}))

  vim.cmd('enew')
  local bufnr = api.nvim_get_current_buf()
  api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  api.nvim_buf_set_option(bufnr, 'filetype', 'nrepl')
  api.nvim_buf_set_name(bufnr, 'nrepl('..bufnr..')')
  vim.cmd(string.format([=[
    inoremap <silent><buffer> <CR> <cmd>lua require'nrepl'.eval_line()<CR>
    nnoremap <silent><buffer> [[ <cmd>lua require'nrepl'.goto_prev()<CR>
    nnoremap <silent><buffer> [] <cmd>lua require'nrepl'.goto_prev(true)<CR>
    nnoremap <silent><buffer> ]] <cmd>lua require'nrepl'.goto_next()<CR>
    nnoremap <silent><buffer> ][ <cmd>lua require'nrepl'.goto_next(true)<CR>
    augroup nrepl
      autocmd BufDelete <buffer> lua require'nrepl'[%d] = nil
    augroup end
  ]=], bufnr))

  local mark_id = 1
  local vim_mode = config.lang == 'vim'
  local this = { bufnr = bufnr }

  --- Append lines to the buffer
  ---@param lines string[]
  ---@param hlgroup string
  local function put(lines, hlgroup)
    local s = fn.line('$')
    api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
    local e = fn.line('$')
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
      _G.print = env.print
      ok, res, n = pcall_res(pcall(res))
      _G.print = prev_print

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
    local ok, res = pcall(fn['nrepl#__evaluate__'], prg)
    if ok then
      put(vim.split(res, '\n', { plain = true, trimempty = true }), 'nreplOutput')
    else
      put({res}, 'nreplError')
    end
  end

  --- Evaluate current line
  function this.eval_line()
    local line = api.nvim_get_current_line()
    local cmd = line:match('^/(.*)%s*$')
    if cmd then
      if fn.match(cmd, [=[\v\C^q%[uit]$]=]) >= 0 then
        M.close(bufnr)
        return
      elseif fn.match(cmd, [=[\v\C^c%[lear]$]=]) >= 0 then
        api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
        return
      elseif fn.match(cmd, [=[\v\C^h%[elp]$]=]) >= 0 then
        put(HELP, 'nreplInfo')
      elseif fn.match(cmd, [=[\v\C^l%[ua]$]=]) >= 0 then
        vim_mode = false
        put({'-- lua --'}, 'nreplInfo')
      elseif fn.match(cmd, [=[\v\C^v%[im]$]=]) >= 0 then
        vim_mode = true
        put({'-- vimscript --'}, 'nreplInfo')
      else
        put({'invalid command'}, 'ErrorMsg')
      end
    else
      if vim_mode then
        vim_eval(line)
      else
        lua_eval(line)
      end
    end

    api.nvim_buf_set_lines(bufnr, -1, -1, false, {''})
    vim.cmd('$')

    -- break undo sequence
    local mode = api.nvim_get_mode().mode
    if mode == 'i' or mode == 'ic' or mode == 'ix' then
      api.nvim_feedkeys(BREAK_UNDO, 'n', true)
    end
  end

  M[bufnr] = this
  if config.on_init then
    config.on_init(bufnr)
  end
end

--- Evaluate current line
function M.eval_line()
  local bufnr = api.nvim_get_current_buf()
  local repl = M[bufnr]
  if repl == nil then error('invalid buffer: '..bufnr) end
  repl.eval_line()
end

--- Close REPL instance
---@param bufnr? string
function M.close(bufnr)
  vim.validate { bufnr = { bufnr, 'number', true } }
  if bufnr == nil or bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  if M[bufnr] == nil then error('invalid buffer: '..bufnr) end
  vim.cmd('stopinsert')
  api.nvim_buf_delete(bufnr, { force = true })
  M[bufnr] = nil
end

--- Go to previous/next output implementation
---@param bufnr string
---@param backward boolean
---@param to_end? boolean
local function goto_output(bufnr, backward, to_end)
  local ranges = {}
  do
    local lnum = 1
    -- TODO: do I have to sort them?
    for _, m in ipairs(api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
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
    local last = fn.line('$')
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

--- Go to previous output
---@param to_end? boolean
function M.goto_prev(to_end)
  vim.validate { to_end = { to_end, 'boolean', true } }
  local bufnr = api.nvim_get_current_buf()
  if M[bufnr] == nil then error('invalid buffer: '..bufnr) end
  goto_output(bufnr, true, to_end)
end

--- Go to next output
---@param to_end? boolean
function M.goto_next(to_end)
  vim.validate { to_end = { to_end, 'boolean', true } }
  local bufnr = api.nvim_get_current_buf()
  if M[bufnr] == nil then error('invalid buffer: '..bufnr) end
  goto_output(bufnr, false, to_end)
end

vim.cmd([[
  hi link nreplError  ErrorMsg
  hi link nreplOutput String
  hi link nreplValue  Number
  hi link nreplInfo   Function
]])

return M
