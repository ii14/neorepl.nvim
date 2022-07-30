local M = {}

---Parses number from token
---@param t nrepl.Lua.Token
---@return number
function M.parse_number(t)
  return t.value:match('^%d+$') and tonumber(t.value) or nil
end

do
  local TO_ESC_SEQS = {
    ['a']  = '\a',
    ['b']  = '\b',
    ['f']  = '\f',
    ['n']  = '\n',
    ['r']  = '\r',
    ['t']  = '\t',
    ['v']  = '\v',
    ['\\'] = '\\',
    ["'"]  = "'",
    ['"']  = '"',
  }

  ---Parses string from token
  ---@param t nrepl.Lua.Token
  ---@return string
  function M.parse_string(t)
    -- don't handle long strings, for now at least
    if t.long then return end
    -- incomplete strings don't have the closing quote
    local str = t.value:sub(2, not t.incomplete and -2 or nil)

    local n = 1
    local m

    while true do
      n = str:find('\\', n)
      if not n then
        return str
      end

      n = n + 1
      m = str:match([=[^([abfnrtv\\'"])]=], n)
      if m then
        str = str:sub(1, n-2)..TO_ESC_SEQS[m]..str:sub(n+1)
      else
        m = str:match([=[^(%d%d?%d?)]=], n)
        if m then
          local b = tonumber(m)
          if b > 255 then return end
          str = str:sub(1, n-2)..string.char(b)..str:sub(n+#m)
        else
          return
        end
      end
    end

    return str
  end
end

do
  local FROM_ESC_SEQS = {
    ['\a'] = '\\a',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
    ['\v'] = '\\v',
  }

  for i = 0, 255 do
    local ch = string.char(i)
    if not FROM_ESC_SEQS[ch] and ch:match('[%c\128-\255]') then
      FROM_ESC_SEQS[ch] = '\\'..i
    end
  end

  ---Escapes a string
  ---@param s string
  ---@return string
  function M.escape_string(s)
    return s:gsub('\\', '\\\\'):gsub('[%c\128-\255]', FROM_ESC_SEQS)
  end
end

return M
