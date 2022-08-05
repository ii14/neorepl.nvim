-- The reason behind all this bullshit is that fetching extmarks from inside
-- nvim_buf_attach callbacks is kinda weird, it looks like sometimes marks are
-- updated *after* the callback, not sure why. To handle that, the processing
-- of buffer changes has to be deferred.
--
-- And to do that, we need to do the following: We are interested only in what parts of
-- the buffer have changed. We need to gather all individual edits made to the buffer
-- and merge them. If lines were added or removed, we have to offset previous edits,
-- so when we later fetch the actual lines, we will still know the correct line numbers
-- after all those changes, already present in the buffer. The processing is triggered
-- when redrawing the screen, using nvim_set_decoration_provider.

local api = vim.api

local NS = api.nvim_create_namespace('neorepl_decor')

---Merges new changes with previous edits.
---
---Takes in and returns a list of packed line ranges.
---`edits` table should only ever be modified by this function,
---to make sure it's sorted and there are no overlapping items.
---Algorithm will assume the input table has those properties.
---
---@param ranges integer[]
---@param start integer
---@param new integer
---@param old integer
---@return integer[]
local function merge(ranges, start, new, old)
  -- assert(type(ranges) == 'table', 'invalid argument #1')
  -- assert(type(start) == 'number' and start >= 0, 'invalid argument #2')
  -- assert(type(new) == 'number' and new >= start, 'invalid argument #3')
  -- assert(type(old) == 'number' and old >= start, 'invalid argument #4')

  -- There are not previous edits, simply add this one.
  if #ranges == 0 then
    ranges[1] = start
    ranges[2] = new
    return ranges
  end

  -- New edit
  local nstart, nnew = start, new
  -- Range marked for removal
  local lower, upper

  for i = #ranges - 1, 1, -2 do
    -- Edit is not overlapping with new changes, and it's
    -- on earlier lines. Any further edits below that point
    -- cannot possibly be affected by new changes. Save the
    -- index as the lower bound.
    if ranges[i+1] < start then
      lower = i
      break
    end

    -- Technically this check is not necessary,
    -- algorithm will still work even without it.
    if new - old ~= 0 then
      local low = new < old and new or old
      -- Offset previous changes according to new changes.
      if ranges[i] >= low then
        ranges[i] = ranges[i] + new - old
        if ranges[i] < low then
          ranges[i] = low
        end
      end
      if ranges[i+1] >= low then
        ranges[i+1] = ranges[i+1] + new - old
        if ranges[i+1] < low then
          ranges[i+1] = low
        end
      end
    end

    if nnew >= ranges[i] then
      -- Changes are overlapping, merge them to the new edit.
      if nstart > ranges[i] then
        nstart = ranges[i]
      end
      if nnew < ranges[i+1] then
        nnew = ranges[i+1]
      end
    else
      -- Being here means that the only possibility left is
      -- that this edit is not overlapping, and is above new
      -- changes. Save the index as the upper bound.
      upper = i
    end
  end

  -- TODO: merge in place
  local res = {}
  for i = 1, lower or 0, 2 do
    res[#res+1] = ranges[i]
    res[#res+1] = ranges[i+1]
  end
  res[#res+1] = nstart
  res[#res+1] = nnew
  for i = upper or 99999999999999, #ranges, 2 do
    res[#res+1] = ranges[i]
    res[#res+1] = ranges[i+1]
  end
  return res
end

---Attached buffers
---@type table<integer, table>
local bufs = {}

---Attach decoration provider
local function attach()
  if next(bufs) ~= nil then
    api.nvim_set_decoration_provider(NS, {
      on_start = function()
        for bufnr, buf in pairs(bufs) do
          if not buf.detach and buf.ranges then
            buf.callback(bufnr, buf.ranges, buf.listener)
            buf.ranges = nil
          end
        end
      end,
    })
  else
    api.nvim_set_decoration_provider(NS, {})
  end
end

---Listen for buffer changes
---
---@param bufnr number
---@param callback fun(bufnr: number, edits: integer[], listener: table)
---@return { detach: function, pause: function, resume: function, flush: function }
local function listen(bufnr, callback)
  assert(type(bufnr) == 'number', 'invalid argument #1')
  assert(type(callback) == 'function', 'invalid argument #2')

  if bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  assert(api.nvim_buf_is_loaded(bufnr), 'invalid buffer')
  assert(bufs[bufnr] == nil, 'buffer already attached')

  local buf

  buf = {
    bufnr = bufnr,
    pause = false,
    detach = false,
    ranges = nil,
    callback = callback,
    listener = {
      ---Pause listener. Changes made to the buffer when
      ---listener is paused will not be registered.
      ---Resume with listener.resume().
      pause = function()
        buf.pause = true
      end,
      ---Resume paused listener.
      resume = function()
        buf.pause = false
      end,
      ---Get current changes and clear the buffer.
      flush = function()
        local res = buf.ranges
        buf.ranges = nil
        return res
      end,
      ---Detach listener.
      detach = function()
        buf.detach = true
        buf[bufnr] = nil
        -- Detach decor provider if there are no other buffers attached
        attach()
      end,
    },
  }

  bufs[bufnr] = buf
  attach()

  assert(api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(_, _, _, start, start_col, _, old, _, _, new, _, _)
      if buf.detach then
        return true
      elseif buf.pause then
        return
      end

      -- Only track changes to the first character on the line. When
      -- edit spans multiple lines, let it through as it is. It could
      -- be a little bit smarter, but it shouldn't be a big deal.
      if start_col > 0 and old == 0 and new == 0 then
        return
      end

      -- Convert to on_lines format
      -- TODO: adjust the merging algorithm instead?
      old = old + start
      new = new + start

      if buf.ranges then
        -- When updating the buffer, we want to look one line ahead.
        -- Add it here so the additional line can be merged too.
        buf.ranges = merge(buf.ranges, start, new + 1, old + 1)
      else
        -- Same here.
        buf.ranges = { start, new + 1 }
      end
    end,
  }), 'nvim_buf_attach failed')

  return buf.listener
end

return {
  listen = listen,
  _merge = merge,
}
