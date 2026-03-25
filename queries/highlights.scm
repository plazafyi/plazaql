; PlazaQL syntax highlighting queries

; ── Comments ────────────────────────────────────────────────────
(line_comment) @comment
(block_comment) @comment

; ── Literals ────────────────────────────────────────────────────
(string) @string
(number) @number
(boolean) @constant.builtin
(atom) @string.special

; ── Keywords (element types, search, boundary) ──────────────────
(element_type) @type
(computation_name) @function.builtin

"search" @keyword
"boundary" @keyword
"point" @function.builtin
"bbox" @function.builtin
"linestring" @function.builtin
"polygon" @function.builtin
"circle" @function.builtin
"dataset" @function.builtin

"true" @constant.builtin
"false" @constant.builtin

; ── Variables and outputs ───────────────────────────────────────
(variable_ref) @variable
(output_ref) @variable.builtin
(output_named_ref) @variable.builtin

(bracket_ref
  variable: (variable_ref) @variable)
(output_bracket_ref
  variable: (output_named_ref) @variable.builtin)

; ── Directives ──────────────────────────────────────────────────
(directive
  "#" @keyword
  name: (identifier) @function.macro)

; ── Methods ─────────────────────────────────────────────────────
(method
  name: (identifier) @function.method)

; ── Tag filters ─────────────────────────────────────────────────
(tag_filter
  key: (identifier) @property)
(regex_key_filter
  key_pattern: (string) @string.regex)

(tag_exists) @constant.builtin
(tag_not_exists) @constant.builtin
(tag_regex (string) @string.regex)
(tag_regex_i (string) @string.regex)
(tag_not_regex (string) @string.regex)

; ── Filter expression functions ─────────────────────────────────
(tag_access
  "t" @variable.builtin)

(prop_accessor
  name: (identifier) @function.builtin)

(geom_function
  name: (identifier) @function.builtin)

(coerce_function
  name: (identifier) @function.builtin)

(string_function
  name: (identifier) @function.builtin)

"size" @function.builtin
"distance" @function.builtin

; ── Keyword arguments ───────────────────────────────────────────
(keyword_argument
  key: (identifier) @property)

; ── Computation ─────────────────────────────────────────────────
(computation
  name: (computation_name) @function.builtin)

; ── Assignments ─────────────────────────────────────────────────
(variable_assignment
  name: (variable_ref) @variable)
(output_assignment
  target: (output_ref) @variable.builtin)
(output_assignment
  target: (output_named_ref) @variable.builtin)

; ── Operators ───────────────────────────────────────────────────
"+" @operator
"-" @operator
"&" @operator
"." @punctuation.delimiter
"=" @operator
"==" @operator
"!=" @operator
">" @operator
"<" @operator
">=" @operator
"<=" @operator
"&&" @operator
"||" @operator
"!" @operator
"*" @operator
"/" @operator
"~" @operator
"~i" @operator
"!~" @operator

; ── Punctuation ─────────────────────────────────────────────────
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"," @punctuation.delimiter
":" @punctuation.delimiter
";" @punctuation.delimiter
"#" @punctuation.special
