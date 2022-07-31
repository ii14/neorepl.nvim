local api = vim.api

local buffers = {}

local M = {
  ---@type neorepl.Repl[]
  _buffers = buffers,
}

---@class neorepl.Config
---@field lang? 'lua'|'vim'
---@field startinsert? boolean
---@field indent? number
---@field inspect? boolean
---@field redraw? boolean
---@field buffer? number|string
---@field window? number|string
---@field on_init? fun(bufnr: number)
---@field env_lua? table|fun():table
---@field histfile? string
---@field histmax? number

---Normalize configuration
---@type fun(config: any): neorepl.Config
local validate do
  local function enum(values)
    return function(v)
      if v == nil then
        return true
      elseif type(v) ~= 'string' then
        return false
      end
      for _, vc in ipairs(values) do
        if v == vc then
          return true
        end
      end
      return false
    end
  end

  local function union(types)
    return function(v)
      if v == nil then
        return true
      end
      local t = type(v)
      for _, tc in ipairs(types) do
        if t == tc then
          return true
        end
      end
      return false
    end
  end

  local function between(min, max)
    return function(v)
      return v == nil or (type(v) == 'number' and v >= min and v <= max)
    end
  end

  function validate(config)
    local c = config and vim.deepcopy(config) or {}

    if c.lang == '' then
      c.lang = nil
    end

    vim.validate {
      lang        = { c.lang,         enum{'lua', 'vim'}, '"lua" or "vim"' },
      startinsert = { c.startinsert,  'boolean', true },
      indent      = { c.indent,       between(0, 32), 'number between 0 and 32' },
      inspect     = { c.inspect,      'boolean', true },
      redraw      = { c.redraw,       'boolean', true },
      on_init     = { c.on_init,      'function', true },
      no_defaults = { c.no_defaults,  'boolean', true },
      buffer      = { c.buffer,       union{'number', 'string'}, 'number or string' },
      window      = { c.window,       union{'number', 'string'}, 'number or string' },
      env_lua     = { c.env_lua,      union{'table', 'function'}, 'table or function' },
      histfile    = { c.histfile,     'string', true },
      histmax     = { c.histmax,      between(1, 1000), 'number between 1 and 1000' },
    }

    return c
  end
end

---@type neorepl.Config Default configuration
local default_config = {
  lang = 'lua',
  startinsert = false,
  indent = 4,
  inspect = true,
  redraw = true,
  no_defaults = false,
  on_init = nil,
  env_lua = nil,
  histfile = (function()
    local ok, path = pcall(vim.fn.stdpath, 'state')
    if not ok then path = vim.fn.stdpath('cache') end
    return path .. '/neorepl_history'
  end)(),
  histmax = 100,
}

---Set default configuration
---@param config? neorepl.Config
function M.config(config)
  -- TODO: merge with the old one.
  -- to do so, we need a way of resetting values back to default,
  -- in particular on_init, env_lua, lang. either false or have neorepl.DEFAULT constant
  config = validate(config)
  if config.buffer ~= nil or config.window ~= nil then
    error('buffer and window cannot be set on a default configuration')
  end
  default_config = config
end

---Create a new REPL instance
---@param config? neorepl.Config
function M.new(config)
  config = validate(vim.tbl_extend('force', default_config, config or {}))
  local repl = require('neorepl.repl').new(config)
  local bufnr = repl.bufnr

  buffers[bufnr] = repl
  api.nvim_create_autocmd('BufDelete', {
    group = api.nvim_create_augroup('neorepl', { clear = false }),
    buffer = bufnr,
    callback = function()
      buffers[bufnr] = nil
    end,
    desc = 'neorepl: teardown repl',
    once = true,
  })

  if config.on_init then
    config.on_init(bufnr)
  end
  if config.startinsert then
    vim.cmd('startinsert')
  end
end

---Close REPL instance
---@param bufnr? string
function M.close(bufnr)
  vim.validate { bufnr = { bufnr, 'number', true } }
  if bufnr == nil or bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  if buffers[bufnr] == nil then
    error('invalid buffer: '..bufnr)
  end
  vim.cmd('stopinsert')
  buffers[bufnr] = nil
  api.nvim_buf_delete(bufnr, { force = true })
end

---Get current REPL
---@return neorepl.Repl
local function get()
  local bufnr = api.nvim_get_current_buf()
  local repl = buffers[bufnr]
  if repl == nil then error('invalid buffer: '..bufnr) end
  return repl
end

---Evaluate current line
function M.eval_line()
  get():eval_line()
end

---Get previous line from the history
function M.hist_prev()
  get():hist_move(true)
end

---Get next line from the history
function M.hist_next()
  get():hist_move(false)
end

---Complete current line
function M.complete()
  get():complete()
end

---Get available completions at current cursor position
---@return number column, string[] completions
function M.get_completion()
  return get():get_completion()
end

---Go to previous output
---@param to_end? boolean
function M.goto_prev(to_end)
  get():goto_output(true, to_end, vim.v.count1)
end

---Go to next output
---@param to_end? boolean
function M.goto_next(to_end)
  get():goto_output(false, to_end, vim.v.count1)
end

do
  local backspace

  local function T(s)
    return api.nvim_replace_termcodes(s, true, false, true)
  end

  function M._restore()
    if backspace then
      api.nvim_set_option('backspace', backspace)
      backspace = nil
    end
  end

  function M.backspace()
    local line = api.nvim_get_current_line()
    local col = vim.fn.col('.')
    local res
    backspace = api.nvim_get_option('backspace')
    if col == 2 and line:sub(1, 1) == '\\' then
      api.nvim_set_option('backspace', 'indent,start,eol')
      res = '<BS><BS>'
    elseif col == 1 and line:sub(1, 1) == '\\' then
      api.nvim_set_option('backspace', 'indent,start,eol')
      res = '<Del><BS>'
    else
      api.nvim_set_option('backspace', 'indent,start')
      res = '<BS>'
    end
    return T(res .. [[<cmd>lua require"neorepl"._restore()<CR>]])
  end

  function M.delete_word()
    local line = api.nvim_get_current_line()
    local col = vim.fn.col('.')
    local res
    backspace = api.nvim_get_option('backspace')
    if col == 2 and line:sub(1, 1) == '\\' then
      api.nvim_set_option('backspace', 'indent,start,eol')
      res = '<BS><BS>'
    elseif col == 1 and line:sub(1, 1) == '\\' then
      api.nvim_set_option('backspace', 'indent,start,eol')
      res = '<Del><BS>'
    else
      api.nvim_set_option('backspace', 'indent,start')
      res = '<C-W>'
    end
    return T(res .. [[<cmd>lua require"neorepl"._restore()<CR>]])
  end

  -- TODO: delete_line
end

return M
