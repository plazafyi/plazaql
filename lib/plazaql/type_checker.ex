defmodule PlazaQL.TypeChecker do
  @moduledoc """
  Type-check a parsed PlazaQL AST.

  Walks the parser AST, assigns types to every expression, validates chain ordering
  and method-type compatibility, tracks variable scope, and produces rich
  `%PlazaQL.Error{}` diagnostics.

  ## Public API

      PlazaQL.TypeChecker.check(ast)

  Returns `{:ok, typed_ast}` or `{:error, [%PlazaQL.Error{}]}`.
  The typed AST mirrors the parser AST with a `:type` key added to each node's
  metadata map.
  """

  alias PlazaQL.Error
  alias PlazaQL.Types

  @type scope :: %{String.t() => %{type: Types.pql_type(), line: pos_integer(), col: pos_integer()}}

  @doc "Type-check a parsed AST. Returns typed AST or errors."
  @spec check([term()]) :: {:ok, [term()]} | {:error, [Error.t()]}
  def check(ast) when is_list(ast) do
    {typed_stmts, errors_rev, _scope} =
      Enum.reduce(ast, {[], [], %{}}, fn stmt, {stmts, errs, scope} ->
        {typed, new_errs, new_scope} = check_statement(stmt, scope)
        {[typed | stmts], [new_errs | errs], new_scope}
      end)

    errors =
      errors_rev
      |> Enum.reverse()
      |> List.flatten()
      |> then(&validate_outputs(ast, &1))

    sorted = Enum.sort_by(errors, &{&1.line, &1.col})

    if sorted == [] do
      {:ok, Enum.reverse(typed_stmts)}
    else
      {:error, sorted}
    end
  end

  @doc "Extract the inferred type from a typed AST expression node."
  @spec expr_type(term()) :: Types.pql_type() | nil
  def expr_type(node) when is_tuple(node) do
    case pos_map(node) do
      %{type: t} -> t
      _ -> nil
    end
  end

  def expr_type(_), do: nil

  # ── Output validation ─────────────────────────────────────────────

  defp validate_outputs(ast, errors) do
    has_output = Enum.any?(ast, &output_stmt?/1)
    has_non_settings = ast != []

    errors =
      if not has_output and has_non_settings do
        errors ++
          [
            %Error{
              line: 1,
              col: 1,
              message: "at least one output statement is required",
              hint: "add an expression like `search(amenity: \"cafe\");` or `$$ = <expression>;`"
            }
          ]
      else
        errors
      end

    output_stmts = Enum.filter(ast, &match?({:output, _, _, _}, &1))
    bare_stmts = Enum.filter(ast, &match?({:bare_output, _, _}, &1))
    simple_outputs = Enum.filter(output_stmts, &match?({:output, nil, _, _}, &1)) ++ bare_stmts
    named_outputs = Enum.reject(output_stmts, &match?({:output, nil, _, _}, &1))

    validate_output_conflicts(simple_outputs, named_outputs, output_stmts, bare_stmts, errors)
  end

  defp output_stmt?({:output, _, _, _}), do: true
  defp output_stmt?({:bare_output, _, _}), do: true
  defp output_stmt?(_), do: false

  defp validate_output_conflicts(simple_outputs, named_outputs, output_stmts, bare_stmts, errors)
       when simple_outputs != [] and named_outputs != [] do
    conflict_pos =
      case List.last(output_stmts) do
        {_, _, _, pos} -> pos
        _ -> List.last(bare_stmts) |> elem(2)
      end

    errors ++
      [
        %Error{
          line: conflict_pos.line,
          col: conflict_pos.col,
          message: "cannot mix simple output and named output (`$$.name = ...`) in the same query",
          hint:
            "use either bare expressions or `$$ = expr;` for single output, or `$$.name = expr;` for multiple named outputs"
        }
      ]
  end

  defp validate_output_conflicts(simple_outputs, _, _, _, errors)
       when length(simple_outputs) > 1 do
    dup_pos =
      case Enum.at(simple_outputs, 1) do
        {:output, _, _, pos} -> pos
        {:bare_output, _, pos} -> pos
      end

    errors ++
      [
        %Error{
          line: dup_pos.line,
          col: dup_pos.col,
          message: "only one simple output is allowed per query",
          hint: "use named outputs (`$$.name = expr;`) for multiple outputs"
        }
      ]
  end

  defp validate_output_conflicts(_, _, _, _, errors), do: errors

  # ── Statement checking ────────────────────────────────────────────

  defp check_statement({:directive, :filter_expr, expr, pos}, scope) do
    errors = check_filter_expr(expr, pos)
    typed = {:directive, :filter_expr, expr, pos}
    {typed, errors, scope}
  end

  defp check_statement({:directive, method_name, args, pos}, scope) do
    {_output_type, compat_errors} = check_method_compat(method_name, :geo_set, pos)
    spatial_errors = check_spatial_args(method_name, args, pos, scope)
    ref_errors = check_var_refs_in_args(args, scope)
    errors = List.flatten([compat_errors, spatial_errors, ref_errors])
    typed = {:directive, method_name, args, pos}
    {typed, errors, scope}
  end

  defp check_statement({:var_assign, name, expr, pos}, scope) do
    dup_errors =
      if Map.has_key?(scope, name) do
        [
          %Error{
            line: pos.line,
            col: pos.col,
            message: "duplicate variable `#{name}`",
            hint: "choose a different name or remove the earlier definition"
          }
        ]
      else
        []
      end

    {typed_expr, expr_type, expr_errors} = check_expr(expr, scope)
    typed = {:var_assign, name, typed_expr, Map.put(pos, :type, expr_type)}
    new_scope = Map.put(scope, name, %{type: expr_type, line: pos.line, col: pos.col})
    {typed, dup_errors ++ expr_errors, new_scope}
  end

  defp check_statement({:output, name, expr, pos}, scope) do
    dup_errors =
      if name && Map.has_key?(scope, "$$." <> name) do
        [
          %Error{
            line: pos.line,
            col: pos.col,
            message: "duplicate output variable `$$.#{name}`",
            hint: "choose a different name or remove the earlier definition"
          }
        ]
      else
        []
      end

    {typed_expr, expr_type, errors} = check_expr(expr, scope)
    typed = {:output, name, typed_expr, Map.put(pos, :type, expr_type)}

    # Named outputs are trackable in scope for later $$.name references
    new_scope =
      if name do
        Map.put(scope, "$$." <> name, %{type: expr_type, line: pos.line, col: pos.col})
      else
        scope
      end

    {typed, dup_errors ++ errors, new_scope}
  end

  defp check_statement({:bare_output, expr, pos}, scope) do
    {typed_expr, expr_type, errors} = check_expr(expr, scope)
    typed = {:bare_output, typed_expr, Map.put(pos, :type, expr_type)}
    {typed, errors, scope}
  end

  # ── Expression type checking ──────────────────────────────────────

  defp check_expr({:search, {:dataset, _slugs} = ds, filters, methods, pos}, scope) do
    base_type = :geo_set
    {typed_methods, final_type, method_errors} = check_method_chain(methods, base_type, scope)
    typed = {:search, ds, filters, typed_methods, Map.put(pos, :type, final_type)}
    {typed, final_type, method_errors}
  end

  defp check_expr({:search, elem_type, filters, methods, pos}, scope) do
    base_type = search_base_type(elem_type)
    {typed_methods, final_type, method_errors} = check_method_chain(methods, base_type, scope)
    typed = {:search, elem_type, filters, typed_methods, Map.put(pos, :type, final_type)}
    {typed, final_type, method_errors}
  end

  defp check_expr({:boundary, filters, pos}, _scope) do
    typed = {:boundary, filters, Map.put(pos, :type, :boundary)}
    {typed, :boundary, []}
  end

  defp check_expr({:computation, comp_type, args, opts, pos}, scope) do
    type = computation_type(comp_type)
    arg_errors = check_var_refs_in_args(args ++ opts, scope)
    typed = {:computation, comp_type, args, opts, Map.put(pos, :type, type)}
    {typed, type, arg_errors}
  end

  defp check_expr({:point, lat, lng, pos}, _scope) do
    typed = {:point, lat, lng, Map.put(pos, :type, :point)}
    {typed, :point, []}
  end

  defp check_expr({:bbox, s, w, n, e, pos}, _scope) do
    typed = {:bbox, s, w, n, e, Map.put(pos, :type, :polygon)}
    {typed, :polygon, []}
  end

  defp check_expr({:linestring, items, pos}, _scope) do
    typed = {:linestring, items, Map.put(pos, :type, :linestring)}
    {typed, :linestring, []}
  end

  defp check_expr({:polygon, items, pos}, _scope) do
    typed = {:polygon, items, Map.put(pos, :type, :polygon)}
    {typed, :polygon, []}
  end

  defp check_expr({:circle, items, pos}, _scope) do
    typed = {:circle, items, Map.put(pos, :type, :polygon)}
    {typed, :polygon, []}
  end

  defp check_expr({:var_ref, name, pos}, scope) do
    case Map.get(scope, name) do
      nil ->
        error = %Error{
          line: pos.line,
          col: pos.col,
          message: "undefined variable `#{name}`",
          hint: "define it first: #{name} = <expression>;"
        }

        typed = {:var_ref, name, Map.put(pos, :type, :geo_set)}
        {typed, :geo_set, [error]}

      %{type: type} ->
        typed = {:var_ref, name, Map.put(pos, :type, type)}
        {typed, type, []}
    end
  end

  defp check_expr({:output_var_ref, name, pos}, scope) do
    scope_key = "$$." <> name

    case Map.get(scope, scope_key) do
      nil ->
        error = %Error{
          line: pos.line,
          col: pos.col,
          message: "undefined output variable `$$.#{name}`",
          hint: "define it first: $$.#{name} = <expression>;"
        }

        typed = {:output_var_ref, name, Map.put(pos, :type, :geo_set)}
        {typed, :geo_set, [error]}

      %{type: type} ->
        typed = {:output_var_ref, name, Map.put(pos, :type, type)}
        {typed, type, []}
    end
  end

  defp check_expr({:chain, _, _, _} = chain, scope), do: check_chain(chain, scope)
  defp check_expr({:chain, _, _} = chain, scope), do: check_chain(chain, scope)

  defp check_expr({op, left, right, pos}, scope)
       when op in [:union, :difference, :intersection] do
    {typed_left, left_type, left_errors} = check_expr(left, scope)
    {typed_right, right_type, right_errors} = check_expr(right, scope)
    result_type = set_op_result_type(op, left_type, right_type)
    typed = {op, typed_left, typed_right, Map.put(pos, :type, result_type)}
    {typed, result_type, left_errors ++ right_errors}
  end

  defp check_expr({:list, items, pos}, scope) do
    item_errors =
      Enum.flat_map(items, fn item ->
        {_, _, errs} = check_expr(item, scope)
        errs
      end)

    typed = {:list, items, Map.put(pos, :type, :scalar)}
    {typed, :scalar, item_errors}
  end

  defp check_expr({:bracket_ref, var_name, attr, pos}, scope) do
    {type, errors} =
      case resolve_var_type(var_name, scope) do
        nil ->
          error = %Error{
            line: pos.line,
            col: pos.col,
            message: "undefined variable `#{var_name}` in bracket reference `#{var_name}[#{attr}]`",
            hint: "define it first: #{var_name} = <expression>;"
          }

          {:value_set, [error]}

        %{type: var_type} ->
          cond do
            Types.geo_element?(var_type) ->
              {:scalar, []}

            Types.geo_set?(var_type) ->
              {:value_set, []}

            true ->
              error = %Error{
                line: pos.line,
                col: pos.col,
                message:
                  "`#{var_name}[#{attr}]` requires a GeoSet or GeoElement, got #{Types.display_name(var_type)}",
                hint: "bracket attribute access only works on feature sets or elements"
              }

              {:value_set, [error]}
          end
      end

    typed = {:bracket_ref, var_name, attr, Map.put(pos, :type, type)}
    {typed, type, errors}
  end

  # Literal values (numbers, strings, identifiers, atoms, booleans) are scalars
  defp check_expr({tag, _, _} = node, _scope)
       when tag in [:number, :string, :identifier, :atom, :boolean],
       do: {node, :scalar, []}

  defp check_expr(other, _scope), do: {other, :scalar, []}

  defp check_chain(chain, scope) do
    {base, methods} = flatten_chain(chain)
    {typed_base, base_type, base_errors} = check_expr(base, scope)
    {typed_methods, final_type, method_errors} = check_method_chain(methods, base_type, scope)
    typed = rebuild_chain(typed_base, typed_methods, final_type)
    {typed, final_type, base_errors ++ method_errors}
  end

  # ── Method chain validation ───────────────────────────────────────

  @group_rank %{source: 0, freely_orderable: 1, late_chain: 2, terminal: 3}

  defp check_method_chain(methods, base_type, scope) do
    initial_ctx = %{
      last_group: :source,
      last_method_name: nil,
      has_around: false,
      has_limit: false,
      output_mode_count: 0,
      current_type: base_type
    }

    {typed_rev, errors_rev, final_ctx} =
      Enum.reduce(methods, {[], [], initial_ctx}, fn method, {acc, errs, ctx} ->
        {typed_method, new_errs, new_ctx} = check_method(method, ctx, scope)
        {[typed_method | acc], [new_errs | errs], new_ctx}
      end)

    flattened_errors =
      errors_rev
      |> Enum.reverse()
      |> List.flatten()

    {Enum.reverse(typed_rev), final_ctx.current_type, flattened_errors}
  end

  # Expression-argument methods: sum, min, max, avg, group_by — expr is an expression tree, not arg list
  @expr_arg_methods [:sum, :min, :max, :avg, :group_by]

  defp check_method({:method, name, expr, pos}, ctx, _scope)
       when name in @expr_arg_methods and not is_list(expr) do
    group = Types.method_group(name)

    ordering_errors = check_ordering(name, group, ctx, pos)

    output_errors =
      if Types.output_mode?(name), do: check_output_exclusivity(name, ctx, pos), else: []

    {output_type, compat_errors} = check_method_compat(name, ctx.current_type, pos)
    expr_errors = check_filter_expr(expr, pos)

    all_errors = List.flatten([ordering_errors, output_errors, compat_errors, expr_errors])

    new_group =
      if @group_rank[group] > @group_rank[ctx.last_group], do: group, else: ctx.last_group

    new_ctx = %{
      ctx
      | last_group: new_group,
        last_method_name: name,
        current_type: output_type,
        output_mode_count: ctx.output_mode_count + if(Types.output_mode?(name), do: 1, else: 0)
    }

    typed = {:method, name, expr, Map.put(pos, :type, output_type)}
    {typed, all_errors, new_ctx}
  end

  # Expression filter: {:method, :filter_expr, expr, pos} — expr is an expression tree, not arg list
  defp check_method({:method, :filter_expr, expr, pos}, ctx, _scope) do
    name = :filter_expr
    group = Types.method_group(name)

    ordering_errors = check_ordering(name, group, ctx, pos)
    {output_type, compat_errors} = check_method_compat(name, ctx.current_type, pos)

    # Type-check the expression tree (validate it produces a boolean)
    expr_errors = check_filter_expr(expr, pos)

    all_errors = List.flatten([ordering_errors, compat_errors, expr_errors])

    new_group =
      if @group_rank[group] > @group_rank[ctx.last_group], do: group, else: ctx.last_group

    new_ctx = %{
      ctx
      | last_group: new_group,
        last_method_name: name,
        current_type: output_type
    }

    typed = {:method, :filter_expr, expr, Map.put(pos, :type, output_type)}
    {typed, all_errors, new_ctx}
  end

  defp check_method({:method, name, args, pos}, ctx, scope) do
    group = Types.method_group(name)

    # 1. Group ordering
    ordering_errors = check_ordering(name, group, ctx, pos)

    # 2. Output mode exclusivity
    output_errors = check_output_exclusivity(name, ctx, pos)

    # 3. Method-type compatibility
    {output_type, compat_errors} = check_method_compat(name, ctx.current_type, pos)

    # 4. Spatial arg type checking
    spatial_errors = check_spatial_args(name, args, pos, scope)

    # 5. Var refs in args
    ref_errors = check_var_refs_in_args(args, scope)

    # 6. Contextual requirements
    context_errors = check_contextual(name, args, ctx, pos)

    all_errors =
      List.flatten([
        ordering_errors,
        output_errors,
        compat_errors,
        spatial_errors,
        ref_errors,
        context_errors
      ])

    new_group =
      if @group_rank[group] > @group_rank[ctx.last_group], do: group, else: ctx.last_group

    new_ctx = %{
      ctx
      | last_group: new_group,
        last_method_name: name,
        current_type: output_type,
        has_around: ctx.has_around or name == :around,
        has_limit: ctx.has_limit or name == :limit,
        output_mode_count: ctx.output_mode_count + if(Types.output_mode?(name), do: 1, else: 0)
    }

    typed = {:method, name, args, Map.put(pos, :type, output_type)}
    {typed, all_errors, new_ctx}
  end

  # ── Ordering & output checks ─────────────────────────────────────

  defp check_ordering(name, group, ctx, pos) do
    category = Types.method_category(name)

    cond do
      ctx.last_group == :terminal ->
        [
          %Error{
            line: pos.line,
            col: pos.col,
            message:
              "`.#{name}()` cannot follow `.#{ctx.last_method_name}()` — output modes must be last in the chain",
            hint: "move `.#{name}()` before the output mode"
          }
        ]

      group == :freely_orderable and ctx.last_group == :late_chain ->
        [
          %Error{
            line: pos.line,
            col: pos.col,
            message:
              "`.#{name}()` (#{category}) cannot follow `.#{ctx.last_method_name}()` (ordering) — ordering methods must come after all other methods",
            hint: "move `.#{name}()` before `.#{ctx.last_method_name}()`"
          }
        ]

      true ->
        []
    end
  end

  defp check_output_exclusivity(name, ctx, pos) do
    if Types.output_mode?(name) and ctx.output_mode_count > 0 do
      [
        %Error{
          line: pos.line,
          col: pos.col,
          message: "multiple output modes — `.#{name}()` conflicts with earlier output mode",
          hint: "use only one output mode per chain (`.count()`, `.ids()`, `.tags()`, or `.skel()`)"
        }
      ]
    else
      []
    end
  end

  # ── Method compatibility ──────────────────────────────────────────

  defp check_method_compat(name, input_type, pos) do
    case Types.method_output_type(name, input_type) do
      {:ok, output_type} ->
        {output_type, []}

      {:error, msg} ->
        hint = simplify_hint(name, input_type)

        error = %Error{
          line: pos.line,
          col: pos.col,
          message: msg,
          hint: hint
        }

        {input_type, [error]}
    end
  end

  defp simplify_hint(:simplify, :point_set),
    do: "remove `.simplify()`, or search for `way` or `relation` types"

  defp simplify_hint(_, _), do: nil

  # ── Spatial argument type checking ────────────────────────────────

  @spatial_with_geometry [
    :within,
    :not_within,
    :around,
    :intersects,
    :not_intersects,
    :contains,
    :not_contains,
    :crosses,
    :touches
  ]

  defp check_spatial_args(name, args, pos, scope) when name in @spatial_with_geometry do
    valid_types = Types.valid_spatial_arg_types(name)

    args
    |> extract_geometry_exprs()
    |> Enum.flat_map(&validate_spatial_arg(&1, name, valid_types, pos, scope))
  end

  defp check_spatial_args(_, _, _, _), do: []

  defp validate_spatial_arg(expr, name, valid_types, pos, scope) do
    case infer_arg_type(expr, scope) do
      {:ok, arg_type} ->
        if arg_type in valid_types do
          []
        else
          [
            %Error{
              line: pos.line,
              col: pos.col,
              message:
                "`.#{name}()` requires #{format_valid_types(valid_types)} but got #{Types.display_name(arg_type)}",
              hint: spatial_hint(name, arg_type)
            }
          ]
        end

      :unknown ->
        []
    end
  end

  @scalar_tags [:number, :string, :identifier, :atom, :boolean]

  defp extract_geometry_exprs(args) do
    Enum.flat_map(args, fn
      {:kwarg, "geometry", expr} -> [expr]
      {:posarg, {tag, _, _}} when tag in @scalar_tags -> []
      {:posarg, expr} when is_tuple(expr) -> [expr]
      _ -> []
    end)
  end

  @arg_type_by_tag %{
    point: :point,
    linestring: :linestring,
    polygon: :polygon,
    bbox: :polygon,
    circle: :polygon,
    boundary: :boundary
  }

  defp infer_arg_type({:var_ref, name, _pos}, scope) do
    case Map.get(scope, name) do
      %{type: type} -> {:ok, type}
      nil -> :unknown
    end
  end

  defp infer_arg_type({:output_var_ref, name, _pos}, scope) do
    case Map.get(scope, "$$." <> name) do
      %{type: type} -> {:ok, type}
      nil -> :unknown
    end
  end

  defp infer_arg_type({:computation, comp_type, _, _, _}, _scope),
    do: {:ok, computation_type(comp_type)}

  defp infer_arg_type(node, _scope) when is_tuple(node) do
    case Map.get(@arg_type_by_tag, elem(node, 0)) do
      nil -> :unknown
      type -> {:ok, type}
    end
  end

  defp infer_arg_type(_, _scope), do: :unknown

  defp format_valid_types(types) do
    Enum.map_join(types, ", ", &Types.display_name/1)
  end

  defp spatial_hint(:within, :route),
    do: "use `.around(distance: 200, geometry: $var)` to search near the route"

  defp spatial_hint(:within, _),
    do: "use a `boundary()`, `polygon()`, or `isochrone()` variable"

  defp spatial_hint(:crosses, _),
    do: "`.crosses()` requires a LineString or Route geometry"

  defp spatial_hint(_, _), do: nil

  # ── Var ref checking in args ──────────────────────────────────────

  defp check_var_refs_in_args(args, scope) do
    Enum.flat_map(args, fn
      {:posarg, {:var_ref, name, ref_pos}} -> check_var_ref(name, ref_pos, scope)
      {:kwarg, _, {:var_ref, name, ref_pos}} -> check_var_ref(name, ref_pos, scope)
      {:posarg, {:output_var_ref, name, ref_pos}} -> check_output_var_ref(name, ref_pos, scope)
      {:kwarg, _, {:output_var_ref, name, ref_pos}} -> check_output_var_ref(name, ref_pos, scope)
      _ -> []
    end)
  end

  defp check_var_ref(name, pos, scope) do
    if Map.has_key?(scope, name) do
      []
    else
      [
        %Error{
          line: pos.line,
          col: pos.col,
          message: "undefined variable `#{name}`",
          hint: "define it first: #{name} = <expression>;"
        }
      ]
    end
  end

  defp check_output_var_ref(name, pos, scope) do
    if Map.has_key?(scope, "$$." <> name) do
      []
    else
      [
        %Error{
          line: pos.line,
          col: pos.col,
          message: "undefined output variable `$$.#{name}`",
          hint: "define it first: $$.#{name} = <expression>;"
        }
      ]
    end
  end

  # ── Contextual requirements ───────────────────────────────────────

  defp check_contextual(:sort, args, ctx, pos) do
    if sort_by_distance?(args) and not ctx.has_around do
      [
        %Error{
          line: pos.line,
          col: pos.col,
          message: "`.sort(by: :distance)` requires a spatial reference point",
          hint: "use `.around(...)` before `.sort(by: :distance)`, or sort by `name` or `osm_id`"
        }
      ]
    else
      []
    end
  end

  defp check_contextual(:offset, _args, %{has_limit: true}, _pos), do: []

  defp check_contextual(:offset, _args, _ctx, pos) do
    [
      %Error{
        line: pos.line,
        col: pos.col,
        message: "`.offset()` requires `.limit()` to be set",
        hint: "add `.limit(n)` before `.offset()`: ...limit(20).offset(10)"
      }
    ]
  end

  defp check_contextual(:member_of, args, _ctx, pos),
    do: check_join_method_args(:member_of, args, pos)

  defp check_contextual(:has_member, args, _ctx, pos),
    do: check_join_method_args(:has_member, args, pos)

  defp check_contextual(:index, args, _ctx, pos) do
    case args do
      [{:posarg, {:number, n, _}}] when is_integer(n) and n > 0 ->
        []

      [{:posarg, {:number, _, _}}] ->
        [
          %Error{
            line: pos.line,
            col: pos.col,
            message: "`.index()` requires a positive integer argument",
            hint: "e.g., `.index(3)` for the third element"
          }
        ]

      _ ->
        [
          %Error{
            line: pos.line,
            col: pos.col,
            message: "`.index()` requires exactly one positive integer argument",
            hint: "e.g., `.index(3)` for the third element"
          }
        ]
    end
  end

  defp check_contextual(_, _, _, _), do: []

  defp sort_by_distance?(args) do
    Enum.any?(args, fn
      {:kwarg, "by", {:identifier, "distance", _}} -> true
      {:kwarg, "by", {:atom, :distance, _}} -> true
      _ -> false
    end)
  end

  # ── Chain flattening ──────────────────────────────────────────────

  defp flatten_chain(chain), do: flatten_chain(chain, [])

  defp flatten_chain({:chain, receiver, method}, acc),
    do: flatten_chain(receiver, [method | acc])

  defp flatten_chain({:chain, receiver, method, _meta}, acc),
    do: flatten_chain(receiver, [method | acc])

  defp flatten_chain(other, acc), do: {other, acc}

  defp rebuild_chain(base, [], _type), do: base

  defp rebuild_chain(base, methods, final_type) do
    last_method = List.last(methods)

    Enum.reduce(methods, base, fn method, receiver ->
      meta = if method == last_method, do: %{type: final_type}, else: %{}
      {:chain, receiver, method, meta}
    end)
  end

  # ── Type inference helpers ────────────────────────────────────────

  defp set_op_result_type(:union, l, r), do: Types.union_type(l, r)
  defp set_op_result_type(:difference, l, _r), do: l
  defp set_op_result_type(:intersection, l, r), do: Types.intersection_type(l, r)

  defp search_base_type(:node), do: :point_set
  defp search_base_type(_), do: :geo_set

  @computation_types %{
    route: :route,
    map_match: :route,
    optimize: :route,
    ev_route: :route,
    isochrone: :isochrone,
    geocode: :point_set,
    reverse_geocode: :point_set,
    autocomplete: :point_set,
    text_search: :point_set,
    nearest: :point_set,
    matrix: :matrix,
    elevation: :elevation,
    elevation_profile: :elevation
  }

  defp computation_type(comp), do: Map.get(@computation_types, comp, :geo_set)

  # ── Variable resolution ──────────────────────────────────────────

  defp resolve_var_type("$$." <> _ = key, scope), do: Map.get(scope, key)
  defp resolve_var_type("$" <> _ = key, scope), do: Map.get(scope, key)
  defp resolve_var_type(name, scope), do: Map.get(scope, name)

  # ── Join method arg validation ──────────────────────────────────

  defp check_join_method_args(method, args, pos) do
    positional = Enum.filter(args, &match?({:posarg, _}, &1))
    kwargs = Enum.filter(args, &match?({:kwarg, _, _}, &1))

    source_errors =
      case positional do
        [] ->
          [
            %Error{
              line: pos.line,
              col: pos.col,
              message: "`.#{method}()` requires a source argument",
              hint: "pass a variable reference or inline `search()` expression"
            }
          ]

        [{:posarg, {:var_ref, _, _}} | _] ->
          []

        [{:posarg, {:output_var_ref, _, _}} | _] ->
          []

        [{:posarg, {:search, _, _, _, _}} | _] ->
          []

        [{:posarg, {:chain, _, _, _}} | _] ->
          []

        [{:posarg, {:chain, _, _}} | _] ->
          []

        _ ->
          [
            %Error{
              line: pos.line,
              col: pos.col,
              message:
                "`.#{method}()` argument must be a variable reference or `search()` expression",
              hint: "e.g., `.#{method}($my_var)` or `.#{method}(search(relation, route: \"bus\"))`"
            }
          ]
      end

    role_errors =
      Enum.flat_map(kwargs, fn
        {:kwarg, "role", {:string, _, _}} ->
          []

        {:kwarg, "role", {:identifier, _, _}} ->
          []

        {:kwarg, "role", _} ->
          [
            %Error{
              line: pos.line,
              col: pos.col,
              message: "`role:` must be a string",
              hint: nil
            }
          ]

        {:kwarg, key, _} ->
          [
            %Error{
              line: pos.line,
              col: pos.col,
              message: "unknown keyword argument `#{key}:` for `.#{method}()`",
              hint: "supported kwargs: `role:`"
            }
          ]
      end)

    source_errors ++ role_errors
  end

  # ── Filter expression validation ─────────────────────────────────

  # Basic structural validation of filter expression trees.
  # We don't do deep type inference here — the executor handles runtime types.
  # We check for obviously invalid constructs.
  defp check_filter_expr({:bin_op, _op, left, right, _pos}, parent_pos) do
    check_filter_expr(left, parent_pos) ++ check_filter_expr(right, parent_pos)
  end

  defp check_filter_expr({:unary_op, _op, operand, _pos}, parent_pos) do
    check_filter_expr(operand, parent_pos)
  end

  defp check_filter_expr({:coerce_func, _func, arg, _pos}, parent_pos) do
    check_filter_expr(arg, parent_pos)
  end

  defp check_filter_expr({:str_func, _func, arg1, arg2, _pos}, parent_pos) do
    check_filter_expr(arg1, parent_pos) ++
      if(arg2, do: check_filter_expr(arg2, parent_pos), else: [])
  end

  defp check_filter_expr({:tag_access, _key, _pos}, _parent_pos), do: []
  defp check_filter_expr({:prop_access, _prop, _pos}, _parent_pos), do: []
  defp check_filter_expr({:geom_func, _func, _pos}, _parent_pos), do: []
  defp check_filter_expr({:number, _, _}, _parent_pos), do: []
  defp check_filter_expr({:string, _, _}, _parent_pos), do: []
  defp check_filter_expr({:bool, _, _}, _parent_pos), do: []
  defp check_filter_expr(_, _parent_pos), do: []

  # ── AST position extraction ───────────────────────────────────────

  defp pos_map(node) when is_tuple(node) do
    last = :erlang.element(tuple_size(node), node)
    if is_map(last), do: last, else: %{}
  end
end
