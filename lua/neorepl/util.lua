-- User utility functions
-- Experimental, stuff can change or get removed from here

local api, fn, uv = vim.api, vim.fn, vim.loop

local util = {}

util.split = function()
  if fn.winwidth(0) > 80 * 2 then
    vim.cmd('vsplit')
  else
    vim.cmd('split')
  end
end

---Global instance
local global = nil
local function open(config, focus)
  local repl = require('neorepl.bufs')[global]
  if repl then
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(win) == global then
        if focus ~= false then
          api.nvim_set_current_win(win)
        end
        return repl, false
      end
    end

    local prev = api.nvim_get_current_win()
    if util.split then
      util.split()
    end
    api.nvim_set_current_buf(global)
    if focus == false then
      api.nvim_set_current_win(prev)
    end
    return repl, false
  else
    local prev = api.nvim_get_current_win()
    if util.split then
      util.split()
    end
    require('neorepl').new(config)
    global = api.nvim_get_current_buf()
    if focus == false then
      api.nvim_set_current_win(prev)
    end
    return require('neorepl.bufs')[global], true
  end
end


---Open a global instance
function util.open()
  open()
  api.nvim_command('startinsert')
end


---Open a global instance and set the context to the current buffer and window
function util.attach()
  local buf = api.nvim_get_current_buf()
  local win = api.nvim_get_current_win()
  local repl = open()
  api.nvim_command('startinsert')
  -- TODO: print notification if context changed
  repl.buffer = buf ~= api.nvim_get_current_buf() and buf or 0
  repl.window = win ~= api.nvim_get_current_win() and win or 0
end


---Run lua file
function util.run_file(path)
  assert(type(path) == 'string', 'expected string')
  path = assert(uv.fs_realpath(path))

  ---@param repl neorepl.Repl
  local function run(repl)
    local time = os.date('%Y-%m-%d %H:%M:%S')
    repl:echo(('%s: %s'):format(time, path), 'neoreplInfo')
    local f, err = loadfile(path)
    if not f then
      repl:echo(err, 'neoreplError')
    else
      repl.lua:eval(f, true)
    end
  end

  local repl, new = open({
    startinsert = false,
    on_init = function(_, repl)
      run(repl)
    end,
  }, false)

  if not new then
    repl:clear()
    run(repl)
    repl:prompt()
  end
end


---Run lua buffer
function util.run_buffer(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = api.nvim_get_current_buf()
  end
  assert(api.nvim_buf_is_loaded(bufnr), 'invalid buffer')

  ---@param repl neorepl.Repl
  local function run(repl)
    local time = os.date('%H:%M:%S')
    local file = api.nvim_buf_get_name(bufnr)
    if file == '' then
      file = ('(buffer#%d)'):format(bufnr)
      repl:echo(('(%s)  buffer %d:  [No Name]'):format(time, bufnr), 'neoreplInfo')
    else
      repl:echo(('(%s)  buffer %d:  %s'):format(time, bufnr, file), 'neoreplInfo')
    end

    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local f, err = loadstring(table.concat(lines, '\n'), '@'..file)
    if not f then
      repl:echo(err, 'neoreplError')
    else
      repl.lua:eval(f, true)
    end
  end

  local repl, new = open({
    startinsert = false,
    on_init = function(_, repl)
      run(repl)
    end,
  }, false)

  if not new then
    repl:clear()
    run(repl)
    repl:prompt()
  end
end

return util
