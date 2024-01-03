if exists('g:loaded_neorepl')
  finish
endif
let g:loaded_neorepl = 1

function! s:comp(A,L,P)
  return filter(['lua', 'vim'], 'stridx(v:val, a:A) == 0')
endfunction
function! s:wrapper(args, mods)
  if empty(a:mods)
    let l:args = [get(a:args, 0, v:null), v:null, v:null]
  else
    let l:args = [get(a:args, 0, v:null), nvim_get_current_buf(), nvim_get_current_win()]
    execute a:mods .. ' split'
  endif
  call luaeval('require"neorepl".new{lang=_A[1], buffer=_A[2], window=_A[3]}', l:args)
endfunction
command! -bar -nargs=? -complete=customlist,s:comp Repl
  \ call <SID>wrapper([<f-args>], <q-mods>)
