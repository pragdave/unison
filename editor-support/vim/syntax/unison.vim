if version < 600
  syn clear
elseif exists("b:current_syntax")
  finish
endif

let b:upperName = "\<[A-Z_][A-Za-z0-9_'!]*\>"
let b:lowerName = "\<[a-z_][A-Za-z0-9_'!]*\>"
let b:anyName   = "\<[a-zA-Z_][A-Za-z0-9_'!]*\>"

syn match uOperator "\v((\=[-!#$%&*+/<=>\\?@^|~]+)|[-!#$%&*+/<>?@^|~]+)"
syn match uDelimiter "[\[\[(){},.]"
syn match uArrow "->"
"x"
"x"" Strings and constants
syn match   uSpecialChar	contained "\\\([0-9]\+\|o[0-7]\+\|x[0-9a-fA-F]\+\|[\"\\'&\\abfnrtv]\|^[A-Z^_\[\\\]]\)"
syn match   uSpecialChar	contained "\\\(NUL\|SOH\|STX\|ETX\|EOT\|ENQ\|ACK\|BEL\|BS\|HT\|LF\|VT\|FF\|CR\|SO\|SI\|DLE\|DC1\|DC2\|DC3\|DC4\|NAK\|SYN\|ETB\|CAN\|EM\|SUB\|ESC\|FS\|GS\|RS\|US\|SP\|DEL\)"
syn match   uSpecialCharError	contained "\\&\|'''\+"
syn region  uString		start=+"+  skip=+\\\\\|\\"+  end=+"+  contains=uSpecialChar
syn match   uCharacter		"[^a-zA-Z0-9_']'\([^\\]\|\\[^']\+\|\\'\)'"lc=1 contains=uSpecialChar,uSpecialCharError
syn match   uCharacter		"^'\([^\\]\|\\[^']\+\|\\'\)'" contains=uSpecialChar,uSpecialCharErro
syn match   uNumber "\v[-+]?\d+(\.\d+)?([eE][-+]?\d+)?"
syn match   uNumber "\v[-+]?0[xX]_*[0-9A-Fa-f]+(\.[0-9A-Fa-f]+)?([pP][-+]?\d+)?"
syn match   uNumber "\v[-+]?0[oO][0-7]+"

syn keyword uKeyword ability cases do else forall handle if let match module structural then type unique use where with

syn match uBoolean "\<\(true\|false\)\>"

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

execute 'syn match uVariable "\v'  . b:lowerName . '"'
execute 'syn match uTermName "\v(' . b:anyName . '\.)*' . b:lowerName . '"'
execute 'syn match uTypedef  "\v(' . b:anyName . '\.)*' . b:lowerName . '\s*:"'
execute 'syn match uType     "\v'  . b:upperName . '"'

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

  HiLink uArrow            Typedef
  HiLink uBelowFold        Comment
  HiLink uBlockComment     uComment
  HiLink uBoolean          Boolean
  HiLink uCharacter        Character
  HiLink uComment          Comment
  HiLink uConditional      Conditional
  HiLink uConditional      Conditional
  HiLink uDebug            Debug
  HiLink uDelimiter        Delimiter
  HiLink uDocBlock         String
  HiLink uDocDirective     uImport
  HiLink uDocEmbed         uImport
  HiLink uFloat            Float
  HiLink uImport           Include
  HiLink uKeyword          Keyword
  HiLink uLineComment      uComment
  HiLink uLink             uType
  HiLink uName             Error
  "Identifier
  HiLink uNumber           Number
  HiLink uOperator         Operator
  HiLink uPunctuation      SpecialChar
  HiLink uPragma           SpecialComment
  HiLink uSpecialChar      SpecialChar
  HiLink uSpecialCharError Error
  HiLink uStatement        Statement
  HiLink uString           String
  HiLink uType             Type
  HiLink uTypedef          Typedef
  HiLink uTermName         Function
  HiLink uVariable         Identifier
  delcommand HiLink
endif


let b:current_syntax = "unison"
"	*Comment	any comment
"
"	*Constant	any constant
"	 String		a string constant: "this is a string"
"	 Character	a character constant: 'c', '\n'
"	 Number		a number constant: 234, 0xff
"	 Boolean	a boolean constant: TRUE, false
"	 Float		a floating point constant: 2.3e10
"
"	*Identifier	any variable name
"	 Function	function name (also: methods for classes)
"
"	*Statement	any statement
"	 Conditional	if, then, else, endif, switch, etc.
"	 Repeat		for, do, while, etc.
"	 Label		case, default, etc.
"	 Operator	"sizeof", "+", "*", etc.
"	 Keyword	any other keyword
"	 Exception	try, catch, throw
"
"	*PreProc	generic Preprocessor
"	 Include	preprocessor #include
"	 Define		preprocessor #define
"	 Macro		same as Define
"	 PreCondit	preprocessor #if, #else, #endif, etc.
"
"	*Type		int, long, char, etc.
"	 StorageClass	static, register, volatile, etc.
"	 Structure	struct, union, enum, etc.
"	 Typedef	A typedef
"
"	*Special	any special symbol
"	 SpecialChar	special character in a constant
"	 Tag		you can use CTRL-] on this
"	 Delimiter	character that needs attention
"	 SpecialComment	special things inside a comment
"	 Debug		debugging statements
"
"	*Underlined	text that stands out, HTML links
"
"	*Ignore		left blank, hidden  |hl-Ignore|
"
"	*Error		any erroneous construct
"
"	*Todo		anything that needs extra attention; mostly the
"			keywords TODO FIXME and XXX
" Options for vi: ts=8 sw=2 sts=2 nowrap noexpandtab ft=vim
