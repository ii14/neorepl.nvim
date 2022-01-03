function! nrepl#__evaluate__(line)
  try
    return execute(a:line, 'silent')
  catch
    return {'exception': v:exception, 'throwpoint': v:throwpoint}
  endtry
endfunction
