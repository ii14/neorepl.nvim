local api = vim.api
local fn = vim.fn

local ns = api.nvim_create_namespace('nrepl')

local M = {}

---@class nreplConfig
---@field lang? 'lua'|'vim'
---@field on_init? function(bufnr: number)
---@field startinsert? boolean
---@field indent? number

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
  if c.startinsert ~= nil and type(c.startinsert) ~= 'boolean' then
    error('invalid startinsert value, expected boolean or nil')
  end
  if c.indent ~= nil and (type(c.indent) ~= 'number' or c.indent < 0 or c.indent > 32) then
    error('invalid indent value, expected positive number, max 32 or nil')
  end
  return c
end

---@type nreplConfig Default configuration
local default_config = {
  indent = 4,
}

--- Set default configuration
---@param config? nreplConfig
function M.config(config)
  default_config = normalize_config(config)
end

--- Create a new REPL instance
---@param config? nreplConfig
function M.new(config)
  config = normalize_config(vim.tbl_extend('force', default_config, config or {}))
  require('nrepl.repl').new(config)
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
    local last = api.nvim_buf_line_count(bufnr)
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

function M.get_completion()
  local bufnr = api.nvim_get_current_buf()
  local repl = M[bufnr]
  if repl == nil then error('invalid buffer: '..bufnr) end

  local line = api.nvim_get_current_line()
  -- TODO: handle repl commands
  if line:sub(1,1) == '/' then
    return
  end

  local pos = api.nvim_win_get_cursor(0)[2]
  line = line:sub(1, pos)
  local completions, start, comptype

  if repl.vim_mode then
    start = line:find('%S+$')
    comptype = 'cmdline'
  else
    -- TODO: completes with the global lua environment, instead of repl env
    start = line:find('[%a_][%w_]*$')
    comptype = 'lua'
  end

  if repl.buffer > 0 then
    if not api.nvim_buf_is_valid(repl.buffer) then
      return
    end
    api.nvim_buf_call(repl.buffer, function()
      completions = fn.getcompletion(line, comptype, 1)
    end)
  else
    completions = fn.getcompletion(line, comptype, 1)
  end

  if completions and #completions > 0 then
    fn.complete(start or pos + 1, completions)
  end
end

return M
