local api, fn = vim.api, vim.fn

---@class neorepl.Config
---@field lang? 'lua'|'vim'
---@field startinsert? boolean
---@field indent? number
---@field inspect? boolean
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

---Default configuration
---@type neorepl.Config
local default_config = {
  lang = 'lua',
  startinsert = true,
  indent = 0,
  inspect = true,
  on_init = nil,
  env_lua = nil,
  histfile = (function()
    local ok, path = pcall(fn.stdpath, 'state')
    return (ok and path or fn.stdpath('cache')) .. '/neorepl_history'
  end)(),
  histmax = 100,
}


---@class neorepl.Bufs
local bufs = {}

---Get current REPL
---@param bufnr number
---@return neorepl.Repl
function bufs.get(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  elseif type(bufnr) ~= 'number' then
    error('expected number')
  end

  if bufs[bufnr] == nil then
    error('invalid repl: '..bufnr)
  end

  return bufs[bufnr]
end

-- inject module
package.loaded['neorepl.bufs'] = bufs


local neorepl = {}

---Set default configuration
---@param config? neorepl.Config
function neorepl.config(config)
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
function neorepl.new(config)
  config = validate(vim.tbl_extend('force', default_config, config or {}))
  require('neorepl.repl').new(config)
end

---Get available completions at current cursor position
---@return number column, string[] completions
function neorepl.get_completion()
  return bufs.get():get_completion()
end

return neorepl
