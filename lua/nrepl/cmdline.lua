assert(vim and vim._expand_pat)

local complete = nil

function vim._expand_pat(pat, env)
  if complete == nil then
    complete = require('nrepl.lua.complete').complete
  end

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
