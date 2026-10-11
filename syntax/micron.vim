" Vim syntax file
" Language: Micron (Reticulum / Nomad Network page markup)

if exists('b:current_syntax')
  finish
endif

syn cluster micronInline contains=micronLink,micronPartial,micronField,micronColor,micronTag,micronAnchor,micronEscape

syn match micronTag     /`[fbclrat!=*_]/
syn match micronTag     /``/
syn match micronAnchor  /`:[A-Za-z0-9_-]*/
syn match micronColor   /`[FB]\x\{3}/
syn match micronColor   /`[FB]T\x\{6}/
syn match micronColor   /`[FB]g\d\d/
syn match micronField   /`<[^>]*>/
syn match micronPartial /`{[^}]*}/
syn match micronLink    /`\[[^\]]*\]/
syn match micronEscape  /\\./

syn match micronDivider /^-.*$/
syn match micronHeading /^>\+.*$/ contains=micronHeadingMarker,@micronInline
syn match micronHeadingMarker /^>\+/ contained

syn match micronComment /^#.*$/
syn match micronShebang /^#!.*$/ contains=micronDirective
syn match micronDirective /\<\(fg\|bg\|c\)=\(\x\{3,8}\|\d\+\)/ contained

" A line that is exactly `= toggles literal mode; nothing inside is parsed.
syn region micronLiteral matchgroup=micronTag start=/^`=$/ end=/^`=$/ keepend

hi def link micronTag           Keyword
hi def link micronAnchor        Label
hi def link micronColor         Constant
hi def link micronField         Identifier
hi def link micronPartial       PreProc
hi def link micronLink          Underlined
hi def link micronEscape        SpecialChar
hi def link micronDivider       Delimiter
hi def link micronHeading       Title
hi def link micronHeadingMarker Statement
hi def link micronComment       Comment
hi def link micronShebang       PreProc
hi def link micronDirective     Keyword
hi def link micronLiteral       String

let b:current_syntax = 'micron'
