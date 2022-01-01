function! s:comp(A,L,P)
  return filter(['lua', 'vim'], 'stridx(v:val, a:A) == 0')
endfunction
command! -bar -nargs=? -complete=customlist,s:comp Nrepl
  \ call luaeval('require"nrepl".new{lang=_A[1]}', [<q-args>])
