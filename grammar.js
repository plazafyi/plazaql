/// <reference types="tree-sitter-cli/dsl" />
// @ts-check


// PlazaQL tree-sitter grammar
// Authoritative reference: Plaza.PlazaQL.Parser (NimbleParsec)

const PREC = {
  OR: 1,
  AND: 2,
  EQ: 3,
  CMP: 4,
  ADD: 5,
  MUL: 6,
  UNARY: 7,
  SET: 8,
  CHAIN: 9,
  CALL: 10,
};

module.exports = grammar({
  name: "plazaql",

  extras: ($) => [/\s/, $.line_comment, $.block_comment],

  word: ($) => $._identifier_token,

  conflicts: ($) => [
    [$._filter_primary, $._primary_expression],
    [$.computation_name, $.geom_function],
    [$._keyword_arg_key, $.identifier],
  ],

  rules: {
    // ── Program (top-level) ──────────────────────────────────────
    program: ($) => repeat($._statement),

    _statement: ($) =>
      choice(
        $.directive,
        $.variable_assignment,
        $.output_assignment,
        $.bare_statement,
      ),

    // ── Comments ─────────────────────────────────────────────────
    line_comment: (_) => token(seq("//", /[^\n]*/)),

    block_comment: ($) =>
      seq("/*", repeat(choice($.block_comment, /[^*\/]/, /\*/, /\//)), "*/"),

    // ── Directives ───────────────────────────────────────────────
    directive: ($) =>
      seq(
        "#",
        field("name", $.identifier),
        "(",
        optional($._directive_args),
        ")",
        ";",
      ),

    _directive_args: ($) =>
      choice($.tag_filter_list, $.filter_expression, $._argument_list),

    // ── Variable assignment: $name = expr; ───────────────────────
    variable_assignment: ($) =>
      seq(
        field("name", $.variable_ref),
        "=",
        field("value", $._expression),
        ";",
      ),

    // ── Output assignment: $$ = expr; or $$.name = expr; ─────────
    output_assignment: ($) =>
      seq(
        field("target", choice($.output_ref, $.output_named_ref)),
        "=",
        field("value", $._expression),
        ";",
      ),

    // ── Bare expression statement: expr; ─────────────────────────
    bare_statement: ($) => seq($._expression, ";"),

    // ── Expressions ──────────────────────────────────────────────
    _expression: ($) => $._set_expression,

    // Set operations: +, -, &
    _set_expression: ($) =>
      choice(
        $.union_expression,
        $.difference_expression,
        $.intersection_expression,
        $._chain_expression,
      ),

    union_expression: ($) =>
      prec.left(
        PREC.SET,
        seq(
          field("left", $._set_expression),
          "+",
          field("right", $._chain_expression),
        ),
      ),

    difference_expression: ($) =>
      prec.left(
        PREC.SET,
        seq(
          field("left", $._set_expression),
          "-",
          field("right", $._chain_expression),
        ),
      ),

    intersection_expression: ($) =>
      prec.left(
        PREC.SET,
        seq(
          field("left", $._set_expression),
          "&",
          field("right", $._chain_expression),
        ),
      ),

    // Method chains: expr.method(args)
    _chain_expression: ($) =>
      choice($.method_call, $._primary_expression),

    method_call: ($) =>
      prec.left(
        PREC.CHAIN,
        seq(
          field("receiver", $._chain_expression),
          ".",
          field("method", $.method),
        ),
      ),

    method: ($) =>
      seq(
        field("name", $.identifier),
        optional(seq("(", optional($._method_args), ")")),
      ),

    _method_args: ($) =>
      commaSep1($._method_arg_item),

    _method_arg_item: ($) =>
      choice(
        $._any_tag_filter,
        $.keyword_argument,
        $.filter_expression,
      ),

    // ── Primary expressions ──────────────────────────────────────
    _primary_expression: ($) =>
      choice(
        $.search_expression,
        $.boundary_expression,
        $.computation,
        $.point_constructor,
        $.bbox_constructor,
        $.linestring_constructor,
        $.polygon_constructor,
        $.circle_constructor,
        $.dataset_source,
        $.list_literal,
        $.output_bracket_ref,
        $.bracket_ref,
        $.output_named_ref,
        $.output_ref,
        $.variable_ref,
        $.boolean,
        $.number,
        $.string,
        $.atom,
        $.filter_function_call,
        $.parenthesized_expression,
        $.bare_identifier,
      ),

    parenthesized_expression: ($) => seq("(", $._expression, ")"),

    // ── Search ───────────────────────────────────────────────────
    search_expression: ($) =>
      prec(
        PREC.CALL,
        seq("search", "(", optional($._search_args), ")"),
      ),

    _search_args: ($) =>
      choice(
        seq($.dataset_source, ",", $.tag_filter_list),
        $.dataset_source,
        seq(field("type", $.element_type), ",", $.tag_filter_list),
        field("type", $.element_type),
        $.tag_filter_list,
      ),

    element_type: (_) => choice("node", "way", "relation", "nwr"),

    // ── Dataset source ───────────────────────────────────────────
    dataset_source: ($) =>
      prec(PREC.CALL, seq("dataset", "(", commaSep1($.string), ")")),

    // ── Tag filters ──────────────────────────────────────────────
    tag_filter_list: ($) => commaSep1($._any_tag_filter),

    _any_tag_filter: ($) => choice($.regex_key_filter, $.tag_filter),

    tag_filter: ($) =>
      seq(
        field("key", $.identifier),
        ":",
        field("value", $._tag_filter_value),
      ),

    regex_key_filter: ($) =>
      seq(
        "~",
        field("key_pattern", $.string),
        ":",
        field("value", $._tag_filter_value),
      ),

    _tag_filter_value: ($) =>
      choice(
        $.tag_not_exists,
        $.tag_exists,
        $.tag_not_regex,
        $.tag_regex_i,
        $.tag_regex,
        $.tag_neq,
        $.tag_id_list,
        $.output_bracket_ref,
        $.bracket_ref,
        $.number,
        $.string,
      ),

    tag_exists: (_) => "*",
    tag_not_exists: (_) => seq("!", "*"),
    tag_regex: ($) => seq("~", $.string),
    tag_regex_i: ($) => seq("~i", $.string),
    tag_not_regex: ($) => seq("!~", $.string),
    tag_neq: ($) => seq("!", $.string),
    tag_id_list: ($) => seq("[", commaSep1($.number), "]"),

    // ── Boundary ─────────────────────────────────────────────────
    boundary_expression: ($) =>
      prec(
        PREC.CALL,
        seq("boundary", "(", optional($.tag_filter_list), ")"),
      ),

    // ── Geometry constructors ────────────────────────────────────
    point_constructor: ($) =>
      prec(PREC.CALL, seq("point", "(", optional($._argument_list), ")")),

    bbox_constructor: ($) =>
      prec(PREC.CALL, seq("bbox", "(", optional($._argument_list), ")")),

    linestring_constructor: ($) =>
      prec(
        PREC.CALL,
        seq("linestring", "(", optional($._argument_list), ")"),
      ),

    polygon_constructor: ($) =>
      prec(PREC.CALL, seq("polygon", "(", optional($._argument_list), ")")),

    circle_constructor: ($) =>
      prec(PREC.CALL, seq("circle", "(", optional($._argument_list), ")")),

    // ── Computation functions ────────────────────────────────────
    computation: ($) =>
      prec(
        PREC.CALL,
        seq(
          field("name", $.computation_name),
          "(",
          optional(field("arguments", $._argument_list)),
          ")",
        ),
      ),

    computation_name: (_) =>
      choice(
        "reverse_geocode",
        "elevation_profile",
        "text_search",
        "map_match",
        "autocomplete",
        "ev_route",
        "isochrone",
        "elevation",
        "optimize",
        "geocode",
        "nearest",
        "matrix",
        "route",
      ),

    // ── Arguments ────────────────────────────────────────────────
    _argument_list: ($) => commaSep1($._argument),

    _argument: ($) => choice($.keyword_argument, $._expression),

    keyword_argument: ($) =>
      seq(
        field("key", alias($._keyword_arg_key, $.identifier)),
        ":",
        field("value", $._keyword_arg_value),
      ),

    // keyword arg keys: regular identifiers plus reserved words that can appear as kwarg keys
    _keyword_arg_key: ($) =>
      choice(
        $._identifier_token,
        "point", "bbox", "linestring", "polygon", "circle",
        "distance", "elevation", "length", "area",
        "node", "way", "relation", "nwr",
        "search", "boundary",
      ),

    // keyword arg values: any primary expression, filter expression, or tag_access
    // (but NOT set expressions, to avoid ambiguity with union +)
    _keyword_arg_value: ($) =>
      choice(
        $._primary_expression,
        $.tag_access,
      ),

    // ── Filter expressions (for .filter(), .sort(), .sum() etc) ──
    filter_expression: ($) => $._filter_or,

    _filter_or: ($) =>
      choice($.filter_or_expression, $._filter_and),

    filter_or_expression: ($) =>
      prec.left(PREC.OR, seq($._filter_or, "||", $._filter_and)),

    _filter_and: ($) =>
      choice($.filter_and_expression, $._filter_eq),

    filter_and_expression: ($) =>
      prec.left(PREC.AND, seq($._filter_and, "&&", $._filter_eq)),

    _filter_eq: ($) =>
      choice($.filter_eq_expression, $._filter_cmp),

    filter_eq_expression: ($) =>
      prec.left(
        PREC.EQ,
        seq($._filter_eq, choice("==", "!="), $._filter_cmp),
      ),

    _filter_cmp: ($) =>
      choice($.filter_cmp_expression, $._filter_add),

    filter_cmp_expression: ($) =>
      prec.left(
        PREC.CMP,
        seq($._filter_cmp, choice(">", "<", ">=", "<="), $._filter_add),
      ),

    _filter_add: ($) =>
      choice($.filter_add_expression, $._filter_mul),

    filter_add_expression: ($) =>
      prec.left(
        PREC.ADD,
        seq($._filter_add, choice("+", "-"), $._filter_mul),
      ),

    _filter_mul: ($) =>
      choice($.filter_mul_expression, $._filter_unary),

    filter_mul_expression: ($) =>
      prec.left(
        PREC.MUL,
        seq($._filter_mul, choice("*", "/"), $._filter_unary),
      ),

    _filter_unary: ($) =>
      choice($.filter_unary_expression, $._filter_primary),

    filter_unary_expression: ($) =>
      prec(PREC.UNARY, seq(choice("!", "-"), $._filter_unary)),

    _filter_primary: ($) =>
      choice(
        $.tag_access,
        $.prop_accessor,
        $.geom_function,
        $.distance_function,
        $.coerce_function,
        $.string_function,
        $.size_function,
        $.search_expression,
        $.boundary_expression,
        $.computation,
        $.point_constructor,
        $.bbox_constructor,
        $.linestring_constructor,
        $.polygon_constructor,
        $.circle_constructor,
        $.dataset_source,
        $.list_literal,
        $.filter_paren_expression,
        $.boolean,
        $.number,
        $.string,
        $.atom,
        $.variable_ref,
        $.output_ref,
        $.output_named_ref,
        $.bracket_ref,
        $.output_bracket_ref,
      ),

    filter_paren_expression: ($) => seq("(", $.filter_expression, ")"),

    tag_access: ($) => seq("t", "[", $.string, "]"),

    prop_accessor: ($) =>
      seq(field("name", alias(choice("id", "type", "lat", "lon"), $.identifier)), "(", ")"),

    geom_function: ($) =>
      seq(
        field("name", alias(choice("length", "area", "is_closed", "elevation"), $.identifier)),
        "(",
        ")",
      ),

    distance_function: ($) =>
      seq("distance", "(", $._primary_expression, ")"),

    coerce_function: ($) =>
      seq(
        field("name", alias(choice("number", "is_number"), $.identifier)),
        "(",
        $.filter_expression,
        ")",
      ),

    string_function: ($) =>
      seq(
        field("name", alias(choice("starts_with", "ends_with", "str_contains"), $.identifier)),
        "(",
        $.filter_expression,
        ",",
        $.filter_expression,
        ")",
      ),

    size_function: ($) => seq("size", "(", $.filter_expression, ")"),

    // filter_function_call is for use in _primary_expression context
    // (e.g., distance(point(...)) in .sort() argument, elevation() with no args)
    filter_function_call: ($) =>
      prec(
        PREC.CALL,
        choice(
          seq(choice("length", "area", "is_closed"), "(", ")"),
          seq("distance", "(", $._primary_expression, ")"),
          seq(choice("number", "is_number"), "(", $.filter_expression, ")"),
        ),
      ),

    // ── List literal ─────────────────────────────────────────────
    list_literal: ($) => seq("[", commaSep1($._expression), "]"),

    // ── Variable / Output references ─────────────────────────────
    variable_ref: ($) => token(seq("$", /[a-zA-Z_][a-zA-Z0-9_]*/)),

    output_ref: (_) => token(prec(1, "$$")),

    output_named_ref: (_) => token(prec(2, seq("$$.", /[a-zA-Z_][a-zA-Z0-9_]*/))),

    bracket_ref: ($) =>
      seq(
        field("variable", $.variable_ref),
        "[",
        field("attribute", choice($.string, $.identifier)),
        "]",
      ),

    output_bracket_ref: ($) =>
      seq(
        field("variable", $.output_named_ref),
        "[",
        field("attribute", choice($.string, $.identifier)),
        "]",
      ),

    // ── Bare identifier ──────────────────────────────────────────
    bare_identifier: ($) => prec(-1, $.identifier),

    // ── Literals ─────────────────────────────────────────────────
    boolean: (_) => choice("true", "false"),

    number: (_) =>
      token(seq(optional("-"), /[0-9]+/, optional(seq(".", /[0-9]+/)))),

    string: (_) =>
      token(
        seq(
          '"',
          repeat(choice(/[^"\\]/, seq("\\", /./),)),
          '"',
        ),
      ),

    atom: ($) => seq(":", $.identifier),

    identifier: ($) => $._identifier_token,

    _identifier_token: (_) => /[a-zA-Z_][a-zA-Z0-9_]*/,
  },
});

/**
 * Creates a comma-separated list with at least one element.
 * @param {RuleOrLiteral} rule
 * @returns {SeqRule}
 */
function commaSep1(rule) {
  return seq(rule, repeat(seq(",", rule)));
}
