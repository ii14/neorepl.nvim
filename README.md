# neorepl

Neovim REPL for lua and vim script

---

Start a new instance with:
```
:Repl
```

In insert mode type `/h` and enter to see available commands.

![demo](media/demo.gif)

---

Starts in lua mode by default. You can switch modes with `/vim` (short version:
`/v`) for vim script and `/lua` (short version: `/l`) for lua. You can also run
one-off commands with them, like for example `/v ls` to list buffers.

Lua has its own environment, variables from the REPL won't leak to the global
environment. If by any chance you do want to add something to the global
environment, it's referenced in the `global` variable. In vim script you can use
the `s:` scope, but it's shared between instances right now.

You can switch buffer and window context with `/b` and `/w` commands, so things
like `vim.api.nvim_set_current_line()` or `:s/foo/bar/g` will run on the other
buffer.

A new REPL instance can be also spawned with `require'neorepl'.new{}`. Example
function that mimics vim's cmdwin or exmode:
```lua
vim.keymap.set('n', 'g:', function()
  -- get current buffer and window
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  -- create a new split for the repl
  vim.cmd('split')
  -- spawn repl and set the context to our buffer
  require('neorepl').new{
    lang = 'vim',
    buffer = buf,
    window = win,
  }
  -- resize repl window and make it fixed height
  vim.cmd('resize 10 | setl winfixheight')
end)
```

For the list of available options see [`:h neorepl-config`](doc/neorepl.txt).

Multiple lines can get evaluated when line continuations start with `\` as the
very first character in the line. If you need to evaluate a line that starts
with `/` or `\`, add a space before. Note that vim script has line escaping that
works just like this. So to break lines in a single expression with vim script,
there has to be two backslashes. By default you can break line in insert mode
with `CTRL-J`.

Plugin ships with its own completion, so it's best to disable other completion
plugins for the `neorepl` filetype. Also highlighting can be kinda buggy with
indent-blankline.nvim plugin, so it's good to disable that too.

It can be done by creating `ftplugin/neorepl.lua` file, for example:
```lua
vim.b.indent_blankline_enabled = false
require('cmp').setup.buffer({ enabled = false })
```

Or by setting `on_init` function in a default config:
```lua
require 'neorepl'.config{
  on_init = function(bufnr)
    -- ...
  end,
}
```
