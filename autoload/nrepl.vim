function! nrepl#__evaluate__(line)
  return execute(a:line, 'silent')
endfunction
