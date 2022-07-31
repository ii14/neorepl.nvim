if exists('g:loaded_neorepl')
  finish
endif
let g:loaded_neorepl = 1

function! s:comp(A,L,P)
  return filter(['lua', 'vim'], 'stridx(v:val, a:A) == 0')
endfunction
command! -bar -nargs=? -complete=customlist,s:comp Repl
  \ call luaeval('require"neorepl".new{lang=_A[1]}', [<q-args>])
