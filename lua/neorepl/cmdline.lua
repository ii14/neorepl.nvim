local prev = assert(vim._expand_pat)

local complete = nil

local function expand(pat, env)
  if complete == nil then
    complete = require('neorepl.lua.complete').complete
  end

  pat = pat or ''
  env = env or _G

  local results, pos = complete(pat, env)
  if not results or #results == 0 then
    return {}, 0
  end

  for i, entry in ipairs(results) do
    results[i] = entry.word
  end

  pos = pos - 1
  if pos < 0 then
    pos = 0
  elseif pos > #pat - 1 then
    pos = #pat - 1
  end

  return results, pos
end

vim._expand_pat = expand

return {
  install = function()
    vim._expand_pat = expand
  end,
  restore = function()
    vim._expand_pat = prev
  end,
}
