local api = vim.api

local M = {}

---@class nreplConfig
---@field lang? 'lua'|'vim'
---@field startinsert? boolean
---@field indent? number
---@field inspect? boolean
---@field redraw? boolean
---@field buffer? number
---@field window? number
---@field on_init? function(bufnr: number)

--- Normalize configuration
---@param config? nreplConfig
local function validate(config)
  local c = config and vim.deepcopy(config) or {}
  if c.lang == '' then
    c.lang = nil
  end
  if c.lang ~= nil and c.lang ~= 'lua' and c.lang ~= 'vim' then
    error('invalid lang value, expected "lua", "vim" or nil')
  end
  if c.startinsert ~= nil and type(c.startinsert) ~= 'boolean' then
    error('invalid startinsert value, expected boolean or nil')
  end
  if c.indent ~= nil and (type(c.indent) ~= 'number' or c.indent < 0 or c.indent > 32) then
    error('invalid indent value, expected positive number, max 32 or nil')
  end
  if c.inspect ~= nil and type(c.inspect) ~= 'boolean' then
    error('invalid inspect value, expected boolean or nil')
  end
  if c.redraw ~= nil and type(c.redraw) ~= 'boolean' then
    error('invalid redraw value, expected boolean or nil')
  end
  if c.on_init ~= nil and type(c.on_init) ~= 'function' then
    error('invalid on_init value, expected function or nil')
  end
  if c.buffer ~= nil and type(c.buffer) ~= 'number' then
    error('invalid buffer value, expected boolean or nil')
  end
  if c.window ~= nil and type(c.window) ~= 'number' then
    error('invalid window value, expected boolean or nil')
  end
  return c
end

---@type nreplConfig Default configuration
local default_config = {
  lang = 'lua',
  startinsert = false,
  indent = 4,
  inspect = false,
  redraw = true,
  on_init = nil,
  buffer = nil,
  window = nil,
}

--- Set default configuration
---@param config? nreplConfig
function M.config(config)
  default_config = validate(config)
end

--- Create a new REPL instance
---@param config? nreplConfig
function M.new(config)
  config = validate(vim.tbl_extend('force', default_config, config or {}))
  require('nrepl.repl').new(config)
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

--- Get current REPL
---@return nreplRepl
local function get()
  local bufnr = api.nvim_get_current_buf()
  local repl = M[bufnr]
  if repl == nil then error('invalid buffer: '..bufnr) end
  return repl
end

--- Evaluate current line
function M.eval_line()
  get():eval_line()
end

--- Go to previous output
---@param to_end? boolean
function M.goto_prev(to_end)
  get():goto_output(true, to_end)
end

--- Go to next output
---@param to_end? boolean
function M.goto_next(to_end)
  get():goto_output(false, to_end)
end

--- Complete current line
function M.complete()
  get():complete()
end

return M
