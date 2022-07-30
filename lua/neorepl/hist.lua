local api, uv, mpack = vim.api, vim.loop, vim.mpack

local PID = assert(uv.getpid())

---@class neorepl.Hist
---@field pos number      position in history
---@field cur string|nil  line before moving through history
local Hist = {}
Hist.__index = Hist

-- TODO: option to disable shared history

local HISTMAX ---@type integer
local HISTFILE ---@type string
local TMPFILE ---@type string

local history ---@type string[]

---Read history file
---@return string[]|nil
local function read()
  local file = io.open(HISTFILE, 'rb')
  if not file then return end
  local ok, hist = pcall(mpack.decode, file:read('*a'))
  file:close()

  -- validate
  if not ok or type(hist) ~= 'table' then
    return
  end
  for _, v in ipairs(hist) do
    if type(v) ~= 'string' then
      return
    end
  end

  return hist
end

---Flush history to file
local function flush()
  -- read history again, something could change outside of current instance
  local hist = read()
  if hist then
    -- create a lookup table for entries
    local lookup = {}
    for _, entry in ipairs(history) do
      lookup[entry] = true
    end
    -- remove duplicate entries
    for i = #hist, 1, -1 do
      if lookup[hist[i]] then
        table.remove(hist, i)
      end
    end
    -- merge current history
    for _, entry in ipairs(history) do
      table.insert(hist, entry)
    end
    history = hist
  end

  -- limit to HISTMAX entries
  for _ = HISTMAX, #history do
    table.remove(history, 1)
  end

  local file = io.open(TMPFILE, 'w+b')
  if not file then return end
  file:write(mpack.encode(history))
  file:flush()
  file:close()
  uv.fs_rename(TMPFILE, HISTFILE)
end

---@param config neorepl.Config
function Hist.new(config)
  HISTMAX = assert(config.histmax)
  HISTFILE = assert(config.histfile)
  TMPFILE = HISTFILE .. '.' .. PID

  if history == nil then
    history = read() or {}
  end

  api.nvim_create_autocmd('VimLeavePre', {
    callback = flush,
    desc = 'neorepl: flush history',
    group = api.nvim_create_augroup('neorepl_history', { clear = true }),
  })

  return setmetatable({
    ents = {},
    pos = 0,
    cur = 1,
  }, Hist)
end

---Get entry count
---@return integer
function Hist:len()
  return #history
end

---Reset position in history
function Hist:reset_pos()
  self.pos = 0
end

---Append lines to history
---@param lines string[]
function Hist:append(lines)
  lines = table.concat(lines, '\n')
  -- remove duplicate entries in history
  for i = #history, 1, -1 do
    if history[i] == lines then
      table.remove(history, i)
    end
  end
  -- save lines to history
  table.insert(history, lines)
end

---Move between entries in history
---@param prev    boolean   previous entry if true, next entry if false
---@param current string[]  current lines
---@return string[]
function Hist:move(prev, current)
  if #history == 0 then
    return
  end

  if self.pos == 0 then
    self.cur = table.concat(current, '\n')
  end

  local nlines
  if prev then
    self.pos = self.pos + 1
    if self.pos > #history then
      self.pos = 0
      nlines = self.cur
    else
      nlines = history[#history - self.pos + 1]
    end
  else
    self.pos = self.pos - 1
    if self.pos == 0 then
      nlines = self.cur
    elseif self.pos < 0 then
      self.pos = #history
      nlines = history[1]
    else
      nlines = history[#history - self.pos + 1]
    end
  end

  if nlines then
    return vim.split(nlines, '\n', { plain = true })
  end
end

return Hist
