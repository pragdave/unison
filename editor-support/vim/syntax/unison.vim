if version < 600
  syn clear
elseif exists("b:current_syntax")
  finish
endif

let b:upperName = "\\<[A-Z_][A-Za-z0-9_'!]*\\>"
let b:lowerName = "\\<[a-z_][A-Za-z0-9_'!]*\\>"
let b:anyName   = "\\<[a-zA-Z_][A-Za-z0-9_'!]*\\>"
let b:termName  = '(' . b:anyName . '\.)*' . b:lowerName 
" let b:fnDef = b:termName . "(\\s+ " . b:lowerName . ")*\\s*="
let b:fnDef =  "add\\(\\s\\+" . b:lowerName . "\\)*="


syn keyword uKeyword ability cases do else forall handle if let match module structural then type unique use where with

syn match uBoolean "\<\(true\|false\)\>"

syn match uOperator "\v((\=[-!#$%&*+/<=>\\?@^|~]+)|[-!#$%&*+/<>?@^|~]+)"
syn match uDelimiter "[\[\[(){},.]"
syn match uArrow "->"

" Docs
syn region  uDocBlock         start="{{" end="}}"  extend fold contains=uDocEmbed,uLink,uDocDirective,uEmbedCode
syn match   uLink             contained "{[A-Z][a-zA-Z0-9_']*\.[a-z][a-zA-Z0-9_'.]*}"
syn match   uDocDirective     contained "@\[\([A-Z][a-zA-Z0-9_']*\.\)\=\<[a-z][a-zA-Z0-9_'.]*\>] \(\<[A-Z][a-zA-Z0-9_']*\.\)\=\<[a-z][a-zA-Z0-9_'.]*\>"
syn match   uDocEmbed         contained "{{[^\}]\+}}"
syn match   uEmbedCode       
     \ contained 
     \ transparent
     \ "\(^\s*[`~]\{3,\}\)\_.\{-}\1\s*$"
     \ contains=ALLBUT,uDocBlock

syn match uVariable "\v<[a-z_][A-Za-z0-9_'!]*>"
syn match uType     "\v<[A-Z_][A-Za-z0-9_'!]*>"
syn match uTermName "\v(<[a-zA-Z_][A-Za-z0-9_'!]*>)*\.<[a-z_][A-Za-z0-9_'!]*>"
syn match uTypeDef  "\v(<[a-zA-Z_][A-Za-z0-9_'!]*\.)*[a-z_][A-Za-z0-9_'!]*\s*:"
syn match uFnDef    "\v(<[a-zA-Z_][A-Za-z0-9_'!]*\.)*[a-z_][A-Za-z0-9_'!]*(\s+[a-z_][A-Za-z0-9_'!]*)+\s\="


" Strings and constants
syn match   uSpecialChar	contained "\\\([0-9]\+\|o[0-7]\+\|x[0-9a-fA-F]\+\|[\"\\'&\\abfnrtv]\|^[A-Z^_\[\\\]]\)"
syn match   uSpecialChar	contained "\\\(BS\|HT\|LF\|VT\|FF\|CR\|SP\|DEL\)"
syn match   uSpecialCharError	contained "\\&\|'''\+"
syn region  uString		start=+"+  skip=+\\\\\|\\"+  end=+"+  contains=uSpecialChar

syn match   uCharacter		"\v\?."
syn match   uCharacter		"\v\?\\."
syn match   uCharacter		"\v\?\\[x][0-9a-fA-F]+"
syn match   uCharacter		"\v\?\\[oO][0-7]+"


syn match   uNumber "\v[-+]?\d+(\.\d+)?([eE][-+]?\d+)?"
syn match   uNumber "\v[-+]?0[xX]_*[0-9A-Fa-f]+(\.[0-9A-Fa-f]+)?([pP][-+]?\d+)?"
syn match   uNumber "\v[-+]?0[oO][0-7]+"

" Comments
syn match   uLineComment      "--.*$"
syn region  uBlockComment     start="{-"   end="-}" fold 
syn region  uBelowFold	      start="^---\(\_.\)*" end="\%$" fold

syn match uDebug "^[A-Za-z]*>.*\(\_s\s*\S[^\n]*\)*" 

" Define the default highlighting.
" For version 5.7 and earlier: only when not done already
" For version 5.8 and later: only when an item doesn't have highlighting yet
if version >= 508 || !exists("did_u_syntax_inits")
  if version < 508
    let did_u_syntax_inits = 1
    command -nargs=+ HiLink hi link <args>
  else
    command -nargs=+ HiLink hi def link <args>
  endif

  HiLink uArrow            Special
  HiLink uBelowFold        Comment
  HiLink uBlockComment     uComment
  HiLink uBoolean          Boolean
  HiLink uCharacter        String
  HiLink uComment          Comment
  HiLink uConditional      Conditional
  HiLink uDebug            Debug
  HiLink uDelimiter        Delimiter
  HiLink uDocBlock         String
  HiLink uDocDirective     uImport
  HiLink uDocEmbed         uImport
  HiLink uFloat            Float
  HiLink uFnDef            Function
  HiLink uImport           Include
  HiLink uKeyword          Keyword
  HiLink uLineComment      uComment
  HiLink uLink             uType
  HiLink uName             Identifier
  HiLink uNumber           Number
  HiLink uOperator         Special
  HiLink uPunctuation      SpecialChar
  HiLink uPragma           SpecialComment
  HiLink uSpecialChar      String
  HiLink uSpecialCharError Error
  HiLink uStatement        Statement
  HiLink uString           String
  HiLink uType             Type
  HiLink uTypedef          Number
  HiLink uTermName         String
  HiLink uVariable         Variable
  delcommand HiLink
endif


let b:current_syntax = "unison"

" Options for vi: ts=2 sw=2 sts=2 nowrap noexpandtab ft=vim
