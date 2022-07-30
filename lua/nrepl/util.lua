local api = vim.api
local fn = vim.fn

local M = {}

---Create a lookup table
---@param t string[]
---@return table<string,boolean>
function M.make_lookup(t)
  local r = {}
  for _, k in ipairs(t) do
    r[k] = true
  end
  return r
end

---Parse buffer
---@param buf string|number
---@param zero_is_current? boolean
---@return number|nil
function M.parse_buffer(buf, zero_is_current)
  local num

  if type(buf) == 'number' then
    num = buf
  elseif type(buf) == 'string' then
    num = buf:match('^%d+$')
    if num then
      num = tonumber(num)
    else
      num = fn.bufnr(buf)
      if num > 0 then
        return num
      else
        return nil
      end
    end
  else
    error('invalid buf type')
  end

  if num == 0 then
    if zero_is_current then
      return api.nvim_get_current_buf()
    else
      return 0
    end
  else
    local ok, ok2 = pcall(api.nvim_buf_is_valid, num)
    if ok and ok2 then
      return num
    end
  end
end

---Parse window
---@param win string|number
---@param zero_is_current? boolean
---@return number|nil
function M.parse_window(win, zero_is_current)
  local num
  local ok, ok2

  if type(win) == 'number' then
    num = win
  elseif type(win) == 'string' then
    num = win:match('^%d+$')
    if num then
      num = tonumber(num)
    else
      ok, num = pcall(fn.winnr, win)
      if not ok or num < 1 then
        return nil
      end
    end
  else
    error('invalid win type')
  end

  if num == 0 then
    if zero_is_current then
      return api.nvim_get_current_win()
    else
      return 0
    end
  elseif num < 0 then
    return nil
  elseif num > 0 and num < 1000 then
    num = fn.win_getid(num)
    if num < 1 then
      return nil
    end
  end

  ok, ok2 = pcall(api.nvim_win_is_valid, num)
  if ok and ok2 then
    return num
  end
end

---Check if lines are empty
---@param lines string[]
---@return boolean
function M.lines_empty(lines)
  for _, line in ipairs(lines) do
    if not line:match('^%s*$') then
      return false
    end
  end
  return true
end

---Check if lines are equal
---@param a string[]
---@param b string[]
---@return boolean
function M.lines_equal(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

return M
