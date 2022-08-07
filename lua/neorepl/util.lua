-- User utility functions
-- Experimental, stuff can change or get removed from here

local api = vim.api

local util = {}

do
  local global = nil

  local function open()
    local repl = require('neorepl.bufs')[global]
    if repl then
      for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if api.nvim_win_get_buf(win) == global then
          api.nvim_set_current_win(win)
          if repl.config.startinsert then
            api.nvim_command('startinsert')
          end
          return repl
        end
      end

      api.nvim_command('split')
      api.nvim_set_current_buf(global)
      if repl.config.startinsert then
        api.nvim_command('startinsert')
      end
      return repl
    else
      api.nvim_command('split')
      require('neorepl').new()
      global = api.nvim_get_current_buf()
      return require('neorepl.bufs')[global]
    end
  end

  ---Open a global instance
  function util.open()
    open()
  end

  ---Open a global instance and set the context to the current buffer and window
  function util.attach()
    local buf = api.nvim_get_current_buf()
    local win = api.nvim_get_current_win()
    local repl = open()
    -- TODO: print notification if context changed
    repl.buffer = buf ~= api.nvim_get_current_buf() and buf or 0
    repl.window = win ~= api.nvim_get_current_win() and win or 0
  end
end

return util
