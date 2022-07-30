local util = require('nrepl.util')

---@class nrepl.Hist
---@field ents string[][]   command history
---@field pos number        position in history
---@field cur string[]|nil  line before moving through history
local Hist = {}
Hist.__index = Hist

function Hist.new()
  return setmetatable({
    ents = {},
    pos = 0,
    cur = 1,
  }, Hist)
end

---Append lines to history
---@param lines string[]
function Hist:append(lines)
  -- remove duplicate entries in history
  for i = #self.ents, 1, -1 do
    if util.lines_equal(self.ents[i], lines) then
      table.remove(self.ents, i)
    end
  end
  -- save lines to history
  table.insert(self.ents, lines)
end

---Move between entries in history
---@param prev    boolean   previous entry if true, next entry if false
---@param current string[]  current lines
function Hist:move(prev, current)
  if #self.ents == 0 then
    return
  end

  if self.pos == 0 then
    self.cur = current
  end

  local nlines
  if prev then
    self.pos = self.pos + 1
    if self.pos > #self.ents then
      self.pos = 0
      nlines = self.cur
    else
      nlines = self.ents[#self.ents - self.pos + 1]
    end
  else
    self.pos = self.pos - 1
    if self.pos == 0 then
      nlines = self.cur
    elseif self.pos < 0 then
      self.pos = #self.ents
      nlines = self.ents[1]
    else
      nlines = self.ents[#self.ents - self.pos + 1]
    end
  end

  return nlines
end

return Hist
