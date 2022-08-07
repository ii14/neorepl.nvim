-- Global registry of REPL instances

---@class neorepl.Bufs
local bufs = {}

---Get current REPL
---@param bufnr number
---@return neorepl.Repl
function bufs.get(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  elseif type(bufnr) ~= 'number' then
    error('expected number')
  end

  if bufs[bufnr] == nil then
    error('invalid repl: '..bufnr)
  end

  return bufs[bufnr]
end

return bufs
