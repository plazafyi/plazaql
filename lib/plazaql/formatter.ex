defmodule PlazaQL.Formatter do
  @moduledoc "Format PlazaQL AST back to well-formatted `.pql` source text."

  @max_line_length 80

  @doc "Format AST nodes to PlazaQL source text."
  @spec format([term()]) :: String.t()
  def format(ast) when is_list(ast) do
    Enum.map_join(ast, "\n\n", &format_statement/1) <> "\n"
  end

  # ── Statements ────────────────────────────────────────────────────

  defp format_statement({:var_assign, name, expr, _pos}) do
    "#{name} = #{format_expr(expr)};"
  end

  defp format_statement({:output, name, expr, _pos}) do
    lhs = if name, do: "$$.#{name}", else: "$$"
    "#{lhs} = #{format_expr(expr)};"
  end

  defp format_statement({:bare_output, expr, _pos}) do
    "#{format_expr(expr)};"
  end

  defp format_statement({:directive, :filter_expr, expr, _pos}) do
    "#filter(#{format_expr(expr)});"
  end

  defp format_statement({:directive, :filter, filters, _pos}) do
    "#filter(#{Enum.map_join(filters, ", ", &format_tag_filter/1)});"
  end

  defp format_statement({:directive, method_name, args, _pos}) do
    "##{method_name}(#{format_arg_list(args)});"
  end

  # ── Expressions ───────────────────────────────────────────────────

  defp format_expr({:search, type, filters, methods, _pos}) do
    search_str = format_search_head(type, filters)
    format_with_methods(search_str, methods)
  end

  defp format_expr({:chain, _, _} = chain), do: format_chain_expr(chain)
  defp format_expr({:chain, _, _, _} = chain), do: format_chain_expr(chain)

  defp format_expr({:boundary, filters, _pos}) do
    "boundary(#{Enum.map_join(filters, ", ", &format_tag_filter/1)})"
  end

  defp format_expr({:computation, comp_type, args, opts, _pos}) do
    "#{comp_type}(#{format_arg_list(args ++ opts)})"
  end

  # Point with extracted numeric coords — use positional style
  defp format_expr({:point, lat, lng, _pos}) when is_number(lat) and is_number(lng) do
    "point(#{format_number(lat)}, #{format_number(lng)})"
  end

  # Point with keyword args
  defp format_expr({:point, args, nil, _pos}) do
    "point(#{format_arg_list(args)})"
  end

  # Bbox with extracted numeric coords
  defp format_expr({:bbox, s, w, n, e, _pos})
       when is_number(s) and is_number(w) and is_number(n) and is_number(e) do
    "bbox(#{format_number(s)}, #{format_number(w)}, #{format_number(n)}, #{format_number(e)})"
  end

  # Bbox with keyword args
  defp format_expr({:bbox, args, nil, nil, nil, _pos}) do
    "bbox(#{format_arg_list(args)})"
  end

  for tag <- ~w(linestring polygon circle)a do
    defp format_expr({unquote(tag), items, _pos}) do
      items_str = Enum.map_join(items, ", ", &format_expr/1)
      "#{unquote(tag)}(#{items_str})"
    end
  end

  defp format_expr({:list, items, _pos}) do
    items_str = Enum.map_join(items, ", ", &format_expr/1)
    "[#{items_str}]"
  end

  defp format_expr({op, left, right, _pos}) when op in [:union, :difference, :intersection] do
    operator =
      case op do
        :union -> "+"
        :difference -> "-"
        :intersection -> "&"
      end

    "#{format_expr(left)} #{operator} #{format_expr(right)}"
  end

  # ── Expression language nodes ─────────────────────────────────────

  defp format_expr({:tag_access, key, _pos}), do: "t[\"#{escape_string(key)}\"]"

  defp format_expr({:prop_access, prop, _pos}), do: "#{prop}()"

  defp format_expr({:geom_func, func, _pos}), do: "#{func}()"

  defp format_expr({:coerce_func, func, arg, _pos}), do: "#{func}(#{format_expr(arg)})"

  defp format_expr({:str_func, :size, arg, nil, _pos}), do: "size(#{format_expr(arg)})"

  defp format_expr({:str_func, func, arg1, arg2, _pos}),
    do: "#{func}(#{format_expr(arg1)}, #{format_expr(arg2)})"

  defp format_expr({:unary_op, :not, operand, _pos}), do: "!#{format_expr(operand)}"
  defp format_expr({:unary_op, :neg, operand, _pos}), do: "-#{format_expr(operand)}"

  @binop_symbols %{
    add: "+",
    sub: "-",
    mul: "*",
    div: "/",
    gt: ">",
    lt: "<",
    gte: ">=",
    lte: "<=",
    eq: "==",
    neq: "!=",
    and: "&&",
    or: "||"
  }

  defp format_expr({:bin_op, op, left, right, _pos}) do
    sym = Map.fetch!(@binop_symbols, op)

    "#{format_expr_maybe_parens(left, op, :left)} #{sym} #{format_expr_maybe_parens(right, op, :right)}"
  end

  # ── Other expression nodes ──────────────────────────────────────

  defp format_expr({:bracket_ref, var_name, attr, _pos}), do: "#{var_name}[#{attr}]"
  defp format_expr({:var_ref, name, _pos}), do: name
  defp format_expr({:output_var_ref, name, _pos}), do: "$$.#{name}"
  defp format_expr({:number, value, _pos}), do: format_number(value)
  defp format_expr({:string, value, _pos}), do: format_string_literal(value)
  defp format_expr({:bool, value, _pos}), do: to_string(value)
  defp format_expr({:atom, value, _pos}), do: ":#{value}"
  defp format_expr({:identifier, name, _pos}), do: name

  # ── Search head ───────────────────────────────────────────────────

  defp format_search_head(type, filters) do
    parts =
      if(type, do: [Atom.to_string(type)], else: []) ++
        Enum.map(filters, &format_tag_filter/1)

    "search(#{Enum.join(parts, ", ")})"
  end

  # ── Tag filters ───────────────────────────────────────────────────

  @filter_prefixes %{eq: "", neq: "!", regex: "~", regex_i: "~i", not_regex: "!~"}

  for {op, prefix} <- @filter_prefixes do
    defp format_tag_filter({unquote(op), key, val}),
      do: "#{key}: #{unquote(prefix)}\"#{escape_string(val)}\""
  end

  defp format_tag_filter({:exists, key}), do: "#{key}: *"
  defp format_tag_filter({:not_exists, key}), do: "#{key}: !*"

  defp format_tag_filter({:eq_num, key, val}), do: "#{key}: #{format_number(val)}"

  defp format_tag_filter({:eq_list, key, vals}) do
    items = Enum.map_join(vals, ", ", &format_number/1)
    "#{key}: [#{items}]"
  end

  defp format_tag_filter({:key_value_regex, key_pattern, val_pattern}),
    do: "~\"#{escape_string(key_pattern)}\": ~\"#{escape_string(val_pattern)}\""

  defp format_tag_filter({:key_regex_exists, key_pattern}),
    do: "~\"#{escape_string(key_pattern)}\": *"

  defp format_tag_filter({:bracket_ref_eq, key, {:bracket_ref, _, _, _} = ref}),
    do: "#{key}: #{format_expr(ref)}"

  # ── Method chain formatting ──────────────────────────────────────

  defp format_with_methods(base_str, []), do: base_str

  defp format_with_methods(base_str, methods) do
    dotted = Enum.map(methods, &".#{format_method(&1)}")
    single_line = base_str <> Enum.join(dotted)

    if String.length(single_line) <= @max_line_length do
      single_line
    else
      base_str <> "\n" <> Enum.map_join(dotted, "\n", &"  #{&1}")
    end
  end

  @expr_arg_methods [:sum, :min, :max, :avg, :group_by]

  defp format_method({:method, name, expr, _pos})
       when name in @expr_arg_methods and not is_list(expr) do
    "#{name}(#{format_expr(expr)})"
  end

  defp format_method({:method, :filter_expr, expr, _pos}) do
    "filter(#{format_expr(expr)})"
  end

  defp format_method({:method, :filter, filters, _pos}) do
    "filter(#{Enum.map_join(filters, ", ", &format_tag_filter/1)})"
  end

  defp format_method({:method, name, args, _pos}) do
    "#{name}(#{format_arg_list(args)})"
  end

  # ── Arguments ─────────────────────────────────────────────────────

  defp format_arg_list(args) do
    Enum.map_join(args, ", ", &format_arg/1)
  end

  defp format_arg({:kwarg, name, value}), do: "#{name}: #{format_expr(value)}"
  defp format_arg({:posarg, value}), do: format_expr(value)

  # ── Chain flattening ──────────────────────────────────────────────

  defp flatten_chain(expr, acc \\ [])
  defp flatten_chain({:chain, receiver, method}, acc), do: flatten_chain(receiver, [method | acc])

  defp flatten_chain({:chain, receiver, method, _meta}, acc),
    do: flatten_chain(receiver, [method | acc])

  defp flatten_chain(other, acc), do: {other, acc}

  defp format_chain_expr(chain) do
    {base, methods} = flatten_chain(chain)
    base_str = format_expr(base)
    base_str = if set_op?(base), do: "(#{base_str})", else: base_str
    format_with_methods(base_str, methods)
  end

  defp set_op?({op, _, _, _}) when op in [:union, :difference, :intersection], do: true
  defp set_op?(_), do: false

  # ── Expression precedence helpers ─────────────────────────────────

  @precedence %{
    or: 1,
    and: 2,
    eq: 3,
    neq: 3,
    gt: 4,
    lt: 4,
    gte: 4,
    lte: 4,
    add: 5,
    sub: 5,
    mul: 6,
    div: 6
  }

  @non_associative_ops [:sub, :div]

  defp format_expr_maybe_parens({:bin_op, child_op, _, _, _} = child, parent_op, side) do
    child_prec = Map.get(@precedence, child_op, 99)
    parent_prec = Map.get(@precedence, parent_op, 99)

    needs_parens =
      child_prec < parent_prec or
        (child_prec == parent_prec and side == :right and parent_op in @non_associative_ops)

    if needs_parens do
      "(#{format_expr(child)})"
    else
      format_expr(child)
    end
  end

  defp format_expr_maybe_parens(child, _parent_op, _side), do: format_expr(child)

  # ── Helpers ───────────────────────────────────────────────────────

  defp format_number(value) when is_number(value), do: to_string(value)

  defp format_string_literal(value), do: "\"#{escape_string(value)}\""

  defp escape_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
  end
end
