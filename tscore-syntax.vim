" Syntax highlighting for .tscore files.

syn match tsDirective "%default-call\>"
syn match tsDirective "%\(dur\|meter\|scale\)\>"
hi tsDirective cterm=underline

syn match tsTrackTitle ">[a-z0-9.-]*"
hi tsTrackTitle ctermfg=DarkBlue

syn region tsString start='"' skip='"(' end='"' oneline
hi tsString ctermfg=DarkBlue

" This goes last, so 'tsDefinition' doesn't override it.
syn match tsComment "--.*$"
hi tsComment cterm=bold

" Turn off >80 column highlight.
match none
