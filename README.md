# nrepl

Neovim REPL for lua and vim script

---

```
:Nrepl
```

In insert mode type `/h` and enter to see available commands.

![screenshot](media/screenshot.png)

---

There is no completion yet, and the completion from plugins is useless and
annoying, it's probably best to turn it off. Also highlighting can be kinda
buggy with indent-blankline.nvim plugin, so it's good to disable that too.

It can be done by creating `ftplugin/nrepl.vim` file, for example:
```viml
let g:indent_blankline_enabled = v:false
call compe#setup({'enabled': v:false}, 0)
```

Or by setting `on_init` function in a default config:
```lua
require 'nrepl'.config{
  on_init = function(bufnr)
    -- ...
  end,
}
```

### TODO

- [ ] Completion
- [ ] Evaluate multiple lines
- [ ] Change buffer/window/tab context
- [ ] Per instance script context for vim script
