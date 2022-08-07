local api, fn = vim.api, vim.fn

---@class neorepl.Vim
---@field repl neorepl.Repl parent
local Vim = {}
Vim.__index = Vim

---Create a new vim context
---@param repl neorepl.Repl
---@param _ neorepl.Config
---@return neorepl.Vim
function Vim.new(repl, _)
  return setmetatable({ repl = repl }, Vim)
end

---Evaluate vim script and append output to the buffer
---@param prg string|string[]
---@return nil|boolean
function Vim:eval(prg)
  if type(prg) == 'table' then
    prg = table.concat(prg, '\n'):gsub('\n%s*\\', ' ')
  elseif type(prg) ~= 'string' then
    error('invalid prg type')
  end

  -- print variables
  if prg:match('^%s*[bgstvw%(]:%s*$') then
    -- use let for plain g:, b:, w:, ...
    prg = 'let '..prg
  elseif prg:match('^%s*[bgstvw%(]:') or prg:match('^%s*%(') then
    prg = 'echo '..prg
  end

  -- call execute() from a vim script file to have script local variables.
  -- context is shared between repl instances. a potential solution is to
  -- create a temporary script for each instance.
  local ok, res
  local ctxres = self.repl:_ctx_exec(function()
    ok, res = pcall(fn['neorepl#__evaluate__'], prg)
    vim.cmd('redraw')
  end)

  if not api.nvim_buf_is_valid(self.repl.bufnr) then
    return false
  elseif not ctxres then
    return
  elseif ok then
    local hlgroup
    if res.result then
      hlgroup = 'neoreplOutput'
      res = vim.split(res.result, '\n', { plain = true, trimempty = true })
    else
      hlgroup = 'neoreplError'
      local throwpoint = res.throwpoint
      res = vim.split(res.exception, '\n', { plain = true, trimempty = true })
      table.insert(res, 1, 'Error detected while processing '..throwpoint..':')
    end
    self.repl:echo(res, hlgroup)
  else
    self.repl:echo(vim.split(tostring(res), '\n', { plain = true, trimempty = true }), 'neoreplError')
  end
end

---Complete line
---@param line string
---@return integer offset, string[] completions
function Vim:complete(line)
  local pos = line:find('[^%s%(%)=%-%+%*|/~%.,%[%]{}&]*$')
  if line:match('^%s*[bgstvw]:') or line:match('^%s*%(') then
    line = 'echo '..line
  end

  local results
  if self.repl:_ctx_exec(function()
    results = fn.getcompletion(line, 'cmdline', 1)
  end) then
    if results and #results > 0 then
      return pos, results
    end
  end
end

return Vim
