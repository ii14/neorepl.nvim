local tinsert, srep = table.insert, string.rep

local M = {}

---@alias nreplLuaTokenType
---| 'comment'    comment
---| 'ident'      identifier
---| 'keyword'    keyword
---| 'number'     number
---| 'op'         operator
---| 'string'     string literal
---| 'unknown'    unknown token

---@class nreplLuaToken
---@field type nreplLuaTokenType  token type
---@field value string            raw value
---@field line number             0-indexed line number
---@field col number              0-indexed column number
---@field long? boolean           string/comment style
---@field incomplete? boolean     is string/comment unclosed

---@alias nreplLuaExpType
---| 'root'     first variable to look up       = ident
---| 'prop'     property accessed through .     = . ident
---| 'index'    property accessed through []    = [ number|string ]
---| 'method'   method                          = : ident
---| 'call1'    function call 1                 = string
---| 'call2'    function call 2                 = ( string )

-- can't inherit from tables, so a union type instead

---@class nreplLuaExpBase
---@field type nreplLuaExpType
---@alias nreplLuaExp nreplLuaExpBase|nreplLuaToken[]

local WHITESPACE = ' \t\v\f\r'
local RE_WHITESPACE = '['..WHITESPACE..']*([^'..WHITESPACE..'])'

local KEYWORDS = require('nrepl.util').make_lookup {
  'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for',
  'function', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat',
  'return', 'then', 'true', 'until', 'while',
}

--- Tokenize lua source code
---@param input string
---@return nreplLuaToken[] tokens, number line, number col
function M.lex(input)
  local line = 0
  local col = 0
  local rest = input

  local function slice(n)
    local value = rest:sub(1, n)
    rest = rest:sub(n + 1)
    col = col + n
    return value
  end

  ---@return nreplLuaToken
  local function next()
    if rest == nil or rest == '' then
      return
    end

    -- remove leading whitespace
    while true do
      -- I guess we don't have to handle \r's?
      local _, pos, ch = rest:find(RE_WHITESPACE)
      if pos == nil then
        col = col + #rest
        return
      elseif ch == '\n' then
        rest = rest:sub(pos + 1)
        line = line + 1
        col = 0
      else
        slice(pos - 1)
        break
      end
    end

    -- save starting position
    local sline, scol = line, col

    -- COMMENTS
    if rest:match('^%-%-') then
      local value = slice(2)
      local long = rest:match('^%[=?=?=?=?%[')
      if long then
        -- LONG COMMENTS
        value = value..slice(#long)
        local re = '^%]'..srep('=', #long - 2)..'%]'
        while true do
          local _, pos, ch = rest:find('([%]\n])')
          if pos == nil then
            value = value..rest
            col = col + #rest
            rest = ''
            return {
              type = 'comment',
              value = value,
              line = sline,
              col = scol,
              long = true,
              incomplete = true,
            }
          elseif ch == '\n' then
            value = value..rest:sub(1, pos)
            rest = rest:sub(pos + 1)
            line = line + 1
            col = 0
          else
            value = value..slice(pos - 1)
            if rest:match(re) then
              return {
                type = 'comment',
                value = value..slice(#long),
                line = sline,
                col = scol,
                long = true,
              }
            else
              value = value..slice(1)
            end
          end
        end
      else
        -- LINE COMMENTS
        local pos = rest:find('\n')
        if pos == nil then
          value = rest
          col = col + #rest
          rest = ''
          return {
            type = 'comment',
            value = value,
            line = sline,
            col = scol,
          }
        else
          value = value..rest:sub(1, pos - 1)
          rest = rest:sub(pos + 1)
          line = line + 1
          col = 0
          return {
            type = 'comment',
            value = value,
            line = sline,
            col = scol,
          }
        end
      end
    end

    -- LONG STRINGS
    do
      local long = rest:match('^%[=?=?=?=?%[')
      if long then
        local value = slice(#long)
        local re = '^%]'..srep('=', #long - 2)..'%]'
        while true do
          local _, pos, ch = rest:find('([%]\n])')
          if pos == nil then
            value = value..rest
            col = col + #rest
            rest = ''
            return {
              type = 'string',
              value = value,
              line = sline,
              col = scol,
              long = true,
              incomplete = true,
            }
          elseif ch == '\n' then
            value = value..rest:sub(1, pos)
            rest = rest:sub(pos + 1)
            line = line + 1
            col = 0
          else
            value = value..slice(pos - 1)
            if rest:match(re) then
              return {
                type = 'string',
                value = value..slice(#long),
                line = sline,
                col = scol,
                long = true,
              }
            else
              value = value..slice(1)
            end
          end
        end
      end
    end

    -- OPERATORS
    do
      local m = rest:match('^[=~<>]=')
        or rest:match('^%.%.?%.?')
        or rest:match('^[:;<>/%*%(%)%-=,{}#%^%+%%%[%]]')
      if m then
        rest = rest:sub(#m + 1)
        col = col + #m
        return {
          type = 'op',
          value = m,
          line = sline,
          col = scol,
        }
      end
    end

    -- IDENTIFIERS
    do
      -- can I rely on %a or does the behavior change with locale or something?
      local m = rest:match('^[%a_][%a%d_]*')
      if m then
        rest = rest:sub(#m + 1)
        col = col + #m
        return {
          type = 'ident',
          value = m,
          line = sline,
          col = scol,
        }
      end
    end

    -- NUMBERS
    do
      local m = rest:match('^0[xX][%da-fA-F]+')
        or rest:match('^%d+%.?%d*[eE][%+%-]?%d+')
        or rest:match('^%d+[%.]?[%deE]*')
      if m then
        rest = rest:sub(#m + 1)
        col = col + #m
        return {
          type = 'number',
          value = m,
          line = sline,
          col = scol,
        }
      end
    end

    -- STRINGS
    do
      local str = rest:match('^[\'"]')
      if str then
        local value = str
        rest = rest:sub(2)
        col = col + 1
        while true do
          local _, pos, ch = rest:find('([\n\\'..str..'])')
          if pos == nil then
            value = value..rest
            col = col + #rest
            rest = ''
            return {
              type = 'string',
              value = value,
              line = sline,
              col = scol,
              incomplete = true,
            }
          elseif ch == str then
            return {
              type = 'string',
              value = value..slice(pos),
              line = sline,
              col = scol,
            }
          elseif ch == '\n' then
            value = value..rest:sub(1, pos)
            rest = rest:sub(pos + 1)
            line = line + 1
            col = 0
            return {
              type = 'string',
              value = value,
              line = sline,
              col = scol,
              incomplete = true,
            }
          else
            value = value..slice(2)
          end
        end
      end
    end

    return {
      type = 'unknown',
      value = slice(1),
      line = sline,
      col = scol,
    }
  end

  local tokens = {}
  while true do
    local token = next()
    if not token then break end
    tinsert(tokens, token)
  end
  return tokens, line, col
end

--- Get last expression
---@param ts nreplLuaToken[]
---@return nreplLuaExp[]
function M.parse(ts)
  local r = {}
  local t = nil ---@type nreplLuaToken
  local i = 0

  local function next() ---@return nreplLuaToken
    i = i + 1
    t = ts[i]
    return t
  end

  while true do
    if not next() then return r end
    if t.type == 'ident' then
      if KEYWORDS[t.value] then goto again end
      tinsert(r, { type = 'root', t })

      while true do
        if not next() then return r end
        if t.type == 'op' then
          if t.value == '.' then
            local exp = { type = 'prop', t }
            tinsert(r, exp)

            if not next() then return r end
            if t.type ~= 'ident' then goto back end
            if KEYWORDS[t.value] then goto back end
            tinsert(exp, t)
          elseif t.value == '[' then
            local exp = { type = 'index', t }
            tinsert(r, exp)

            if not next() then return r end
            -- TODO: parse booleans
            if t.type ~= 'number' and t.type ~= 'string' then goto back end
            tinsert(exp, t)

            if not next() then return r end
            if t.type ~= 'op' and t.type ~= ']' then goto back end
            tinsert(exp, t)
          elseif t.value == ':' then
            local exp = { type = 'method', t }
            tinsert(r, exp)

            if not next() then return r end
            if t.type ~= 'ident' then goto back end
            tinsert(exp, t)

            if not next() then return r end
            goto back -- no point in parsing method calls
          elseif t.value == '(' then
            -- include function calls with string as an argument for require
            local exp = { type = 'call2', t }
            tinsert(r, exp)

            if not next() then return r end
            if t.type ~= 'string' then goto back end
            tinsert(exp, t)

            if not next() then return r end
            if t.type ~= 'op' and t.value ~= ')' then goto back end
            tinsert(exp, t)
          else goto back end
        elseif t.type == 'string' then
          -- include function calls with string as an argument for require
          tinsert(r, { type = 'call1', t })
        else goto back end
      end
    else
      goto again
    end

    ::back::
    i = i - 1
    t = ts[i]
    ::again::
    r = {}
  end
  return r
end

return M
