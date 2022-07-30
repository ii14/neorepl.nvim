local fn = vim.fn

---@class nrepl.Vim
---@field repl nrepl.Repl parent
local Vim = {}
Vim.__index = Vim

---Create a new vim context
---@param repl nrepl.Repl
---@param _ nrepl.Config
---@return nrepl.Vim
function Vim.new(repl, _)
  local this = setmetatable({
    repl = repl,
  }, Vim)

  return this
end

---Evaluate vim script and append output to the buffer
---@param prg string
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
  if not self.repl:exec_context(function()
    ok, res = pcall(fn['nrepl#__evaluate__'], prg)
    if self.repl.redraw then
      vim.cmd('redraw')
    end
  end) then
    return
  end

  if ok then
    local hlgroup
    if res.result then
      hlgroup = 'nreplOutput'
      res = vim.split(res.result, '\n', { plain = true, trimempty = true })
    else
      hlgroup = 'nreplError'
      local throwpoint = res.throwpoint
      res = vim.split(res.exception, '\n', { plain = true, trimempty = true })
      table.insert(res, 1, 'Error detected while processing '..throwpoint..':')
    end
    self.repl:put(res, hlgroup)
  else
    self.repl:put(vim.split(tostring(res), '\n', { plain = true, trimempty = true }), 'nreplError')
  end
end

---Complete line
---@param line string
---@return string[] results, number position
function Vim:complete(line)
  local pos = line:find('[^%s%(%)=%-%+%*|/~%.,]*$')
  if line:match('^%s*[bgstvw]:') or line:match('^%s*%(') then
    line = 'echo '..line
  end

  local results
  if not self.repl:exec_context(function()
    results = fn.getcompletion(line, 'cmdline', 1)
  end) then
    return
  end

  if results and #results > 0 then
    return pos, results
  end
end

return Vim
