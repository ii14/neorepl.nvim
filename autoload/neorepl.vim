function! neorepl#__evaluate__(line)
  try
    return {'result': execute(a:line, 'silent')}
  catch
    return {'exception': v:exception, 'throwpoint': v:throwpoint}
  endtry
endfunction
