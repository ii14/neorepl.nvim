# nrepl

Neovim REPL for lua and vim script

Although already usable, it's work in progress, things can change at any time.
The name of the plugin will probably change too, since this name is apparently
already taken.

---

```
:Repl
```

In insert mode type `/h` and enter to see available commands.

![screenshot](media/screenshot.png)

---

Plugin ships with its own completion, a half-assed one at the moment, but
still, so it's best to disable other completion plugins for the `nrepl`
filetype. Also highlighting can be kinda buggy with indent-blankline.nvim
plugin, so it's good to disable that too.

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

---

### TODO

- [X] Completion
  - [X] Vim script (should be the same as on the command line)
  - [X] Lua (not perfect, I hope to either find something that works or to roll out my own)
  - [X] REPL commands (works for commands names only, no arguments yet)
- [X] History
  - [X] Save and recall single lines
  - [X] Make history work with multiple lines
  - [ ] Save and recall context, was it lua or vimscript
- [X] Evaluate multiple lines
  - [X] Break line with `NL` (`CTRL-J`)
  - [ ] Evaluate visual selection
- [X] Context change
  - [X] Buffer
  - [X] Window
- [ ] Per instance script context for vim script
- [X] `[[`, `]]`, `[]`, `][` key bindings
- [ ] Key binding or text object for selecting last output
