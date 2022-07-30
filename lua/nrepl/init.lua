local api = vim.api

local M = {
  ---@type nreplRepl[]
  buffers = {},
}

---@class nreplConfig
---@field lang? 'lua'|'vim'
---@field startinsert? boolean
---@field indent? number
---@field inspect? boolean
---@field redraw? boolean
---@field buffer? number|string
---@field window? number|string
---@field on_init? fun(bufnr: number)
---@field env_lua? table|fun():table

---Normalize configuration
---@type fun(config: any): nreplConfig
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
    }

    return c
  end
end

---@type nreplConfig Default configuration
local default_config = {
  lang = 'lua',
  startinsert = false,
  indent = 4,
  inspect = true,
  redraw = true,
  no_defaults = false,
  on_init = nil,
  env_lua = nil,
}

---Set default configuration
---@param config? nreplConfig
function M.config(config)
  -- TODO: merge with the old one.
  -- to do so, we need a way of resetting values back to default,
  -- in particular on_init, env_lua, lang. either false or have nrepl.DEFAULT constant
  config = validate(config)
  if config.buffer ~= nil or config.window ~= nil then
    error('buffer and window cannot be set on a default configuration')
  end
  default_config = config
end

---Create a new REPL instance
---@param config? nreplConfig
function M.new(config)
  config = validate(vim.tbl_extend('force', default_config, config or {}))
  local repl = require('nrepl.repl').new(config)
  local bufnr = repl.bufnr
  M.buffers[bufnr] = repl
  vim.cmd(string.format([[
    augroup nrepl
      autocmd BufDelete <buffer> lua require'nrepl'.buffers[%d] = nil
    augroup end
  ]], bufnr))
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
  if M.buffers[bufnr] == nil then
    error('invalid buffer: '..bufnr)
  end
  vim.cmd('stopinsert')
  M.buffers[bufnr] = nil
  api.nvim_buf_delete(bufnr, { force = true })
end

---Get current REPL
---@return nreplRepl
local function get()
  local bufnr = api.nvim_get_current_buf()
  local repl = M.buffers[bufnr]
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

return M
