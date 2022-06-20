function! s:comp(A,L,P)
  return filter(['lua', 'vim'], 'stridx(v:val, a:A) == 0')
endfunction
command! -bar -nargs=? -complete=customlist,s:comp Repl
  \ call luaeval('require"nrepl".new{lang=_A[1]}', [<q-args>])

function! s:cmdwin() abort
  let l:bufnr = bufnr()
  let l:winid = win_getid()
  split
  call luaeval('require"nrepl".new{lang="vim",buffer=_A[1],window=_A[2]}',
    \ [l:bufnr, l:winid])
  resize 10
  setlocal winfixheight
endfunction
nnoremap <silent> g: <cmd>call <SID>cmdwin()<CR>
