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

syn match nreplCmdError   contained "^/.*"
syn match nreplArgsError  contained "\s*\zs.*"
syn match nreplBoolean    contained "\(t\|f\|true\|false\)\ze\s*$"
syn match nreplString     contained "\s\zs\S.*"
syn match nreplNumber     contained "\d\+\ze\s*$"

syn cluster NREPL add=nreplCmdError,nreplCmd,nreplVim,nreplLua
syn region nreplVim matchgroup=nreplCmd start="^/v\%[im]\>" skip="^\\" end="^" keepend contains=@VIM contained transparent
syn region nreplLua matchgroup=nreplCmd start="^/l\%[ua]\>" skip="^\\" end="^" keepend contains=@LUA contained transparent
syn match nreplCmd "^/b\%[uffer]\a\@!"  contained nextgroup=nreplNumber,nreplString,nreplArgsError skipwhite
syn match nreplCmd "^/w\%[indow]\a\@!"  contained nextgroup=nreplNumber,nreplString,nreplArgsError skipwhite
syn match nreplCmd "^/i\%[nspect]\a\@!" contained nextgroup=nreplBoolean,nreplArgsError skipwhite
syn match nreplCmd "^/ind\%[ent]\a\@!"  contained nextgroup=nreplNumber,nreplArgsError skipwhite
syn match nreplCmd "^/r\%[edraw]\a\@!"  contained nextgroup=nreplBoolean,nreplArgsError skipwhite
syn match nreplCmd "^/c\%[lear]\a\@!"   contained nextgroup=nreplArgsError skipwhite
syn match nreplCmd "^/q\%[uit]\a\@!"    contained nextgroup=nreplArgsError skipwhite
syn match nreplCmd "^/h\%[elp]\a\@!"    contained nextgroup=nreplArgsError skipwhite

hi link nreplError      Error
hi link nreplCmdError   nreplError
hi link nreplArgsError  nreplError
hi link nreplCmd        Function
hi link nreplContinue   LineNr
hi link nreplBoolean    Boolean
hi link nreplString     String
hi link nreplNumber     Number

" match line breaks independently, outside of :syntax highlighting
call matchadd('nreplContinue', '^\\')

let b:current_syntax = 'nrepl'
