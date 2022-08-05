local ipairs, unpack = ipairs, unpack
local tinsert = table.insert

local api = vim.api

local b_get_lines = api.nvim_buf_get_lines
local b_set_lines = api.nvim_buf_set_lines
local b_line_count = api.nvim_buf_line_count

local m_get = api.nvim_buf_get_extmarks
local m_set = api.nvim_buf_set_extmark
local m_del = api.nvim_buf_del_extmark

local w_list = api.nvim_list_wins
local w_get_buf = api.nvim_win_get_buf
local w_get_cursor = api.nvim_win_get_cursor
local w_set_cursor = api.nvim_win_set_cursor

-- Create namespaces for input and output marks,
-- so they can be queried individually.
local NS_I = api.nvim_create_namespace('neorepl_input')
local NS_O = api.nvim_create_namespace('neorepl_output')

---Can backspace
local function can_backspace(win)
  win = win or 0
  local row = w_get_cursor(win)[1]
  local buf = w_get_buf(win)

  local line = b_get_lines(buf, row - 1, row, false)[1]
  if not line or not line:find('^\\') then
    return false
  end

  local mark = m_get(buf, NS_O, { row - 1, 0 }, 0, { limit = 1, details = true })[1]
  return row > (mark and (mark[4].end_row + 1) or 1)
end

---Get lines under cursor
---@param win? integer
---@return string[] lines, integer start, integer end
local function get_line(win)
  win = win or 0
  local row = w_get_cursor(win)[1]
  local buf = w_get_buf(win)

  -- Set the lower bound to the end of the output or the
  -- first line, so you can't break a line from that.
  local bound do
    local mark = m_get(buf, NS_O, { row - 1, 0 }, 0, { limit = 1, details = true })[1]
    bound = mark and (mark[4].end_row + 1) or 1
  end

  -- TODO: should getting a line on the output be handled somehow?

  -- Get current and next line
  local c, n = unpack(b_get_lines(buf, row - 1, row + 1, false), 1, 2)
  -- Range
  local fst, lst = row, row

  -- Look behind
  while fst > bound and c and c:find('^\\') do
    c = b_get_lines(buf, fst - 2, fst - 1, false)[1]
    if not c then break end
    fst = fst - 1
  end
  -- Look ahead
  while n and n:find('^\\') do
    lst = lst + 1
    n = b_get_lines(buf, lst, lst + 1, false)[1]
  end

  -- TODO: reuse already fetched lines
  local lines = b_get_lines(buf, fst - 1, lst, false)
  for i, line in ipairs(lines) do
    -- Remove line break characters
    lines[i] = line:gsub('^\\', '')
  end
  return lines, fst, lst
end

local EXTMARK_INPUT_OPTS = {
  right_gravity = false,
  sign_text = '>',
  sign_hl_group = 'Function',
  priority = 90,
}

local function on_update(buf, ranges)
  for i = 1, #ranges, 2 do
    -- A set of output lines
    local output_lines = {} do
      -- Get marks in edited range
      local marks = m_get(buf, NS_O, { ranges[i], 0 }, { ranges[i+1], 0 }, { details = true })
      for _, mark in ipairs(marks) do
        -- TODO: create a list of ranges instead of a set?
        for j = mark[2], mark[4].end_row - 1 do
          output_lines[j] = true
        end
      end
      -- A mark can span multiple lines, get one mark before that too
      local mark = m_get(buf, NS_O, { ranges[i], 0 }, 0, { limit = 1, details = true })[1]
      if mark then
        for j = mark[2], mark[4].end_row - 1 do
          output_lines[j] = true
        end
      end
    end

    -- A table of lnum -> id of an existing mark
    local marks = {}
    for _, mark in ipairs(m_get(buf, NS_I, { ranges[i], 0 }, { ranges[i+1], 0 }, {})) do
      if not marks[mark[2]] then
        marks[mark[2]] = mark[1]
      else
        -- Delete potential duplicate marks
        m_del(buf, NS_I, mark[1])
      end
    end

    -- Update input prompt marks
    for lnum, line in ipairs(b_get_lines(buf, ranges[i], ranges[i+1], false)) do
      lnum = ranges[i] + lnum - 1
      -- First line and the line after output section can't be a continuation
      if (lnum ~= 0 and line:find('^\\') and not output_lines[lnum-1]) or output_lines[lnum] then
        if marks[lnum] then
          -- Remove mark if it's already there
          m_del(buf, NS_I, marks[lnum])
        end
      elseif not marks[lnum] then
        -- Create a input prompt mark
        m_set(buf, NS_I, lnum, 0, EXTMARK_INPUT_OPTS)
      end
    end
  end
end

---@class neorepl.Buf
---@field bufnr integer
---@field listener table
local Buf = {}
Buf.__index = Buf

---@param bufnr integer
---@return neorepl.Buf
local function new(bufnr)
  m_set(bufnr, NS_I, 0, 0, EXTMARK_INPUT_OPTS)
  return setmetatable({
    bufnr = bufnr,
    listener = require('neorepl.update').listen(bufnr, on_update),
  }, Buf)
end

---Append output lines
---@param lines string[]
---@param group string
function Buf:append(lines, group)
  local lnum = b_line_count(self.bufnr)

  self.listener.pause()
  b_set_lines(self.bufnr, -1, -1, false, lines)
  self.listener.resume()

  local opts = {
    right_gravity = true,
    end_row = lnum + #lines,
    hl_group = group,
    hl_eol = true,
    sign_text = '<',
    sign_hl_group = 'Question',
    priority = 100,
  }

  -- TODO: check if output section is of the same type before merging
  local mark = m_get(self.bufnr, NS_O, -1, 0, { limit = 1, details = true })[1]
  if mark and mark[4].end_row == lnum and mark[4].hl_group == group then
    lnum = mark[2]
    opts.id = mark[1]
  end

  m_set(self.bufnr, NS_O, lnum, 0, opts)
end

---Append prompt
---@param bufnr integer
local function prompt(bufnr)
  bufnr = bufnr or 0
  b_set_lines(bufnr, -1, -1, false, {''})
  -- Move cursor to the bottom
  local lnum = b_line_count(bufnr)
  for _, win in ipairs(w_list()) do
    if w_get_buf(win) == bufnr then
      w_set_cursor(win, { lnum, 0 })
    end
  end
end

---Go to previous/next output implementation
---@param backward boolean
---@param to_end? boolean
local function goto_output(backward, to_end, count)
  -- TODO: move between individual input section as well
  count = count or 1
  local ranges = {}
  do
    local lnum = 1
    for _, m in ipairs(m_get(0, NS_O, 0, -1, { details = true })) do
      local s = m[2] + 1
      local e = m[4].end_row
      if e >= s then
        -- Insert ranges between extmarks
        if s > lnum then
          tinsert(ranges, { lnum, s - 1 })
        end
        tinsert(ranges, { s, e })
        lnum = e + 1
      end
    end
    -- Insert last range
    local last = b_line_count(0)
    if last >= lnum then
      tinsert(ranges, { lnum, last })
    end
  end

  local lnum = w_get_cursor(0)[1]
  for i, range in ipairs(ranges) do
    if lnum >= range[1] and lnum <= range[2] then
      if backward and not to_end and lnum > range[1] then
        if count == 1 then
          w_set_cursor(0, { range[1], 0 })
          return
        else
          count = count - 1
        end
      elseif not backward and to_end and lnum < range[2] then
        if count == 1 then
          w_set_cursor(0, { range[2], 0 })
          return
        else
          count = count - 1
        end
      end

      if backward then
        count = -count
      end

      local idx = i + count
      if idx > #ranges then
        idx = #ranges
      elseif idx < 1 then
        idx = 1
      end
      range = ranges[idx]
      if range then
        w_set_cursor(0, { (to_end and range[2] or range[1]), 0 })
      end
      return
    end
  end
end

local function clear(bufnr)
  api.nvim_buf_clear_namespace(bufnr, NS_I, 0, -1)
  api.nvim_buf_clear_namespace(bufnr, NS_O, 0, -1)
  api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
end

return {
  new = new,
  get_line = get_line,
  goto_output = goto_output,
  prompt = prompt,
  clear = clear,
  can_backspace = can_backspace,
}
