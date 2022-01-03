if exists('b:current_syntax')
  finish
endif

function! s:include(name, paths)
  for l:path in a:paths
    try
      execute 'syntax include' a:name l:path
    catch /E484/
    endtry
  endfor
  if exists('b:current_syntax')
    unlet b:current_syntax
  endif
endfunction

call s:include('@VIM', [
  \ 'syntax/vim/generated.vim',
  \ 'syntax/vim.vim',
  \ 'syntax/after/vim.vim'
  \ ])

call s:include('@LUA', [
  \ 'syntax/lua.vim',
  \ 'syntax/after/lua.vim'
  \ ])

" vim overrides for leading backslash
syn clear vimContinue
syn match vimContinue "^\\\zs\s*\\"
syn clear vimMapRhsExtend
syn match vimMapRhsExtend contained "^\\\s*\\.*$" contains=vimContinue

syn match   nreplCmdError "^/.*"

syn match   nreplArgsError  contained "\s*\zs.*"
syn match   nreplBoolean    contained "\(t\|f\|true\|false\)\ze\s*$"
syn match   nreplString     contained "\s\zs\S.*"
syn match   nreplNumber     contained "\d\+\ze\s*$"

" vim and lua one-off commands
syn region nreplVim matchgroup=nreplCmd start="^/v\%[im]\>" skip="^\\" end="^" keepend contains=@VIM fold transparent
syn region nreplLua matchgroup=nreplCmd start="^/l\%[ua]\>" skip="^\\" end="^" keepend contains=@LUA fold transparent

" vim and lua regions
syn cluster NREPL add=nreplCmdError,nreplCmd,nreplVim,nreplLua
syn region nreplVimStart matchgroup=nreplCmd start="^/v\%[im]\s*$" end="^\ze/l\%[ua]\s*$" keepend contains=nreplVimRegion,@NREPL
syn region nreplLuaStart matchgroup=nreplCmd start="^/l\%[ua]\s*$" end="^\ze/v\%[im]\s*$" keepend contains=nreplLuaRegion,@NREPL
syn region nreplVimRegion start="^[^/\\]" skip="^\\" end="^" keepend contains=@VIM contained fold transparent
syn region nreplLuaRegion start="^[^/\\]" skip="^\\" end="^" keepend contains=@LUA contained fold transparent

syn match nreplCmd "^/b\%[uffer]\a\@!"  nextgroup=nreplNumber,nreplString,nreplArgsError skipwhite
syn match nreplCmd "^/w\%[indow]\a\@!"  nextgroup=nreplNumber,nreplString,nreplArgsError skipwhite
syn match nreplCmd "^/i\%[nspect]\a\@!" nextgroup=nreplBoolean,nreplArgsError skipwhite
syn match nreplCmd "^/ind\%[ent]\a\@!"  nextgroup=nreplNumber,nreplArgsError skipwhite
syn match nreplCmd "^/r\%[edraw]\a\@!"  nextgroup=nreplBoolean,nreplArgsError skipwhite
syn match nreplCmd "^/c\%[lear]\a\@!"   nextgroup=nreplArgsError skipwhite
syn match nreplCmd "^/q\%[uit]\a\@!"    nextgroup=nreplArgsError skipwhite
syn match nreplCmd "^/h\%[elp]\a\@!"    nextgroup=nreplArgsError skipwhite

hi link nreplError      Error
hi link nreplCmdError   nreplError
hi link nreplArgsError  nreplError
hi link nreplCmd        Function
hi link nreplContinue   LineNr
hi link nreplBoolean    Boolean
hi link nreplString     String
hi link nreplNumber     Number

" generate dynamically
syn region nreplStart start="\%>0l^[^/\\]" skip="^\\" end="^" keepend contains=@LUA fold

" match line breaks independently, outside of :syntax highlighting
call matchadd('nreplContinue', '^\\')

let b:current_syntax = 'nrepl'
