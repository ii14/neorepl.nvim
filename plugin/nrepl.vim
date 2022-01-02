function! s:comp(A,L,P)
  return filter(['lua', 'vim'], 'stridx(v:val, a:A) == 0')
endfunction
command! -bar -nargs=? -complete=customlist,s:comp Repl
  \ call luaeval('require"nrepl".new{lang=_A[1]}', [<q-args>])

inoremap <Plug>(nrepl-eval-line)  <cmd>lua require'nrepl'.eval_line()<CR>
inoremap <Plug>(nrepl-break-line) <CR><C-U>\
inoremap <Plug>(nrepl-hist-prev)  <cmd>lua require'nrepl'.hist_prev()<CR>
inoremap <Plug>(nrepl-hist-next)  <cmd>lua require'nrepl'.hist_next()<CR>
inoremap <Plug>(nrepl-complete)   <cmd>lua require'nrepl'.complete()<CR>

noremap <Plug>(nrepl-[[) <cmd>lua require'nrepl'.goto_prev()<CR>
noremap <Plug>(nrepl-[]) <cmd>lua require'nrepl'.goto_prev(true)<CR>
noremap <Plug>(nrepl-]]) <cmd>lua require'nrepl'.goto_next()<CR>
noremap <Plug>(nrepl-][) <cmd>lua require'nrepl'.goto_next(true)<CR>

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
