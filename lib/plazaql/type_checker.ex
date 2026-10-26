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
  alias PlazaQL.GeometryRef
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
    errors = check_filter_expr(expr, pos, scope)
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

    kwarg_errors =
      check_kwarg_names(comp_type, opts, pos) ++
        check_computation_kwargs(comp_type, opts, pos) ++
        check_computation_args(comp_type, args, opts, pos) ++
        check_truck_kwargs(comp_type, opts, pos) ++
        check_transit_kwargs(comp_type, opts, pos) ++
        check_dataset_kwargs(opts, pos)

    typed = {:computation, comp_type, args, opts, Map.put(pos, :type, type)}
    {typed, type, arg_errors ++ kwarg_errors}
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

  # Sort with expression argument: {:method, :sort_expr, expr, order, pos}
  defp check_method({:method, :sort_expr, expr, order, pos}, ctx, scope) do
    group = Types.method_group(:sort)
    ordering_errors = check_ordering(:sort, group, ctx, pos)
    {output_type, compat_errors} = check_method_compat(:sort, ctx.current_type, pos)
    expr_errors = check_filter_expr(expr, pos, scope)

    all_errors = List.flatten([ordering_errors, compat_errors, expr_errors])

    new_group =
      if @group_rank[group] > @group_rank[ctx.last_group], do: group, else: ctx.last_group

    new_ctx = %{
      ctx
      | last_group: new_group,
        last_method_name: :sort,
        current_type: output_type,
        output_mode_count: ctx.output_mode_count
    }

    typed = {:method, :sort_expr, expr, order, Map.put(pos, :type, output_type)}
    {typed, all_errors, new_ctx}
  end

  # Expression-argument methods: sum, min, max, avg, group_by — expr is an expression tree, not arg list
  @expr_arg_methods [:sum, :min, :max, :avg, :group_by]

  defp check_method({:method, name, expr, pos}, ctx, scope)
       when name in @expr_arg_methods and not is_list(expr) do
    group = Types.method_group(name)

    ordering_errors = check_ordering(name, group, ctx, pos)

    output_errors =
      if Types.output_mode?(name), do: check_output_exclusivity(name, ctx, pos), else: []

    {output_type, compat_errors} = check_method_compat(name, ctx.current_type, pos)
    expr_errors = check_filter_expr(expr, pos, scope)

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
  defp check_method({:method, :filter_expr, expr, pos}, ctx, scope) do
    name = :filter_expr
    group = Types.method_group(name)

    ordering_errors = check_ordering(name, group, ctx, pos)
    {output_type, compat_errors} = check_method_compat(name, ctx.current_type, pos)

    # Type-check the expression tree (validate it produces a boolean)
    expr_errors = check_filter_expr(expr, pos, scope)

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

    # 7. Reference-geometry args (.overlap_fraction(geom))
    geom_ref_errors = check_geometry_ref_method(name, args, pos, scope)

    all_errors =
      List.flatten([
        ordering_errors,
        output_errors,
        compat_errors,
        spatial_errors,
        ref_errors,
        context_errors,
        geom_ref_errors
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

  # `.around(distance, geometry)`: the first positional argument is the
  # distance (a number or a number variable such as `$r = 100`), never the
  # geometry.
  defp check_spatial_args(:around, [{:posarg, _distance} | rest], pos, scope),
    do: check_spatial_args(:around_geometry, rest, pos, scope)

  defp check_spatial_args(:around_geometry, args, pos, scope) do
    valid_types = Types.valid_spatial_arg_types(:around)

    args
    |> extract_geometry_exprs()
    |> Enum.flat_map(&validate_spatial_arg(&1, :around, valid_types, pos, scope))
  end

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

  defp check_contextual(:tile, args, _ctx, pos) do
    positional = for {:posarg, arg} <- args, do: arg
    kwargs = for {:kwarg, key, value} <- args, do: {key, value}

    coord_errors =
      case positional do
        [{:number, z, _}, {:number, x, _}, {:number, y, _}]
        when is_integer(z) and is_integer(x) and is_integer(y) ->
          check_tile_coords(z, x, y, pos)

        _ ->
          [
            %Error{
              line: pos.line,
              col: pos.col,
              message: "`.tile()` requires three integer arguments: zoom, x and y",
              hint: "e.g., `.tile(14, 4823, 6160)`"
            }
          ]
      end

    coord_errors ++ Enum.flat_map(kwargs, &check_tile_kwarg(&1, pos))
  end

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
    elevation_profile: :elevation,
    centroid: :point_set,
    expansion: :line_set,
    place_lookup: :point_set
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
  # We check for obviously invalid constructs and overlap_fraction() references.
  defp check_filter_expr({:bin_op, _op, left, right, _pos}, parent_pos, scope) do
    check_filter_expr(left, parent_pos, scope) ++ check_filter_expr(right, parent_pos, scope)
  end

  defp check_filter_expr({:unary_op, _op, operand, _pos}, parent_pos, scope) do
    check_filter_expr(operand, parent_pos, scope)
  end

  defp check_filter_expr({:coerce_func, _func, arg, _pos}, parent_pos, scope) do
    check_filter_expr(arg, parent_pos, scope)
  end

  defp check_filter_expr({:str_func, _func, arg1, arg2, _pos}, parent_pos, scope) do
    check_filter_expr(arg1, parent_pos, scope) ++
      if(arg2, do: check_filter_expr(arg2, parent_pos, scope), else: [])
  end

  defp check_filter_expr({:geom_func, :overlap_fraction, ref, pos}, parent_pos, scope) do
    check_geometry_ref(ref, pos || parent_pos, scope, report_undefined: true)
  end

  defp check_filter_expr(_, _parent_pos, _scope), do: []

  # ── Reference geometry validation (overlap_fraction) ────────────

  @geometry_ref_hint "pass `polygon(point(lat, lng), ...)`, `bbox(s, w, n, e)`, `$var`, or `$$.name`"
  @geometry_ref_message "`overlap_fraction()` expects a polygon(...), bbox(...), or a variable holding polygons"

  # Variable types that cannot hold polygons
  @non_polygonal_types [
    :point,
    :linestring,
    :point_set,
    :line_set,
    :route,
    :matrix,
    :elevation,
    :scalar,
    :value_set,
    :grouped_set
  ]

  defp check_geometry_ref_method(:overlap_fraction, args, pos, scope) do
    case args do
      [{:posarg, geom}] ->
        ref =
          case GeometryRef.from_ast(geom) do
            {:ok, ref} -> ref
            :error -> {:invalid, geom}
          end

        # Undefined variables are already reported by check_var_refs_in_args
        check_geometry_ref(ref, pos, scope, report_undefined: false)

      _ ->
        [
          %Error{
            line: pos.line,
            col: pos.col,
            message: "`.overlap_fraction()` takes exactly one geometry argument",
            hint: @geometry_ref_hint
          }
        ]
    end
  end

  defp check_geometry_ref_method(_name, _args, _pos, _scope), do: []

  defp check_geometry_ref({:polygon, _rings}, _pos, _scope, _opts), do: []

  defp check_geometry_ref({:set_ref, "$$." <> name = key}, pos, scope, opts) do
    case Map.get(scope, key) do
      nil ->
        if opts[:report_undefined], do: check_output_var_ref(name, pos, scope), else: []

      %{type: type} ->
        check_ref_type(key, type, pos)
    end
  end

  defp check_geometry_ref({:set_ref, name}, pos, scope, opts) do
    key = "$" <> name

    case Map.get(scope, key) do
      nil -> if opts[:report_undefined], do: check_var_ref(key, pos, scope), else: []
      %{type: type} -> check_ref_type(key, type, pos)
    end
  end

  defp check_geometry_ref(_invalid, pos, _scope, _opts) do
    [%Error{line: pos.line, col: pos.col, message: @geometry_ref_message, hint: @geometry_ref_hint}]
  end

  defp check_ref_type(var_name, type, pos) when type in @non_polygonal_types do
    [
      %Error{
        line: pos.line,
        col: pos.col,
        message: "#{@geometry_ref_message}, but `#{var_name}` is #{Types.display_name(type)}",
        hint: @geometry_ref_hint
      }
    ]
  end

  defp check_ref_type(_var_name, _type, _pos), do: []

  # ── Computation keyword arguments ───────────────────────────────

  # The keywords each computation accepts: the parameters of the REST endpoint
  # it stands in for. Anything else is a type error naming the computation, so
  # a misspelt or misplaced keyword is never silently dropped.
  @route_kwargs ~w(origin destination mode steps alternatives waypoints depart_at traffic_model
                   exclude overview geometries annotations lang units verbal avoid_datasets
                   voice_instructions banner_instructions roundabout_exits voice_units
                   waypoint_names)
  @geocode_filter_kwargs ~w(focus country_code bbox layers layer boundary_gid limit lang
                           datasets dataset_name_field)

  @geocode_layers ~w(address admin place poi street postalcode neighbourhood locality county region country dataset)

  # truck vehicle options (`mode: "truck"`), checked by check_truck_kwargs/3.
  @truck_option_kwargs ~w(height width length weight axle_load axle_count hazmat)

  # transit options (`mode: "transit"`), checked by check_transit_kwargs/3.
  @transit_option_kwargs ~w(use_bus use_rail use_transfers max_walk_m max_transfers)

  @computation_kwargs %{
    route: @route_kwargs ++ @truck_option_kwargs ++ @transit_option_kwargs,
    ev_route:
      @route_kwargs ++
        ~w(battery battery_capacity_wh initial_charge_pct min_charge_pct connector_types min_power_kw),
    isochrone:
      ~w(center time mode denoise generalize avoid_datasets depart_at) ++
        @truck_option_kwargs ++ @transit_option_kwargs,
    geocode:
      ~w(query addresses address neighbourhood locality county region postalcode country) ++
        @geocode_filter_kwargs,
    autocomplete: ["query" | @geocode_filter_kwargs],
    text_search: ~w(query limit bbox focus),
    reverse_geocode: ~w(point radius limit include layer lang datasets),
    nearest: ~w(point radius),
    matrix:
      ~w(origins destinations mode annotations fallback_speed avoid_datasets) ++
        @truck_option_kwargs,
    map_match: ~w(points mode radiuses),
    optimize: ~w(waypoints mode roundtrip),
    elevation: ~w(point points),
    elevation_profile: ~w(points),
    centroid: ~w(locations mode metric exclude),
    expansion:
      ~w(action origin destination center time origins destinations mode exclude expansion_properties),
    place_lookup: ~w(ids)
  }

  @doc false
  @spec computation_kwargs() :: %{atom() => [String.t()]}
  def computation_kwargs(), do: @computation_kwargs

  defp check_kwarg_names(comp_type, opts, pos) do
    accepted = Map.get(@computation_kwargs, comp_type, [])

    for {:kwarg, key, value} <- opts,
        error = kwarg_error(comp_type, key, value, accepted),
        error != nil do
      {message, hint} = error
      %Error{line: pos.line, col: pos.col, message: message, hint: hint}
    end
  end

  # Truck options on a computation without them get check_truck_kwargs/3's
  # own message ("`centroid()` has no truck options"); one error, not two.
  defp kwarg_error(comp_type, key, value, accepted) do
    cond do
      key in accepted -> option_error(comp_type, key, value)
      key in @truck_option_kwargs -> nil
      key in @transit_option_kwargs -> nil
      true -> unknown_kwarg_error(comp_type, key, accepted)
    end
  end

  defp option_error(comp_type, key, value) do
    case option_value_error(comp_type, key, value) do
      nil -> nil
      hint -> {"invalid `#{key}:` for `#{comp_type}()`", hint}
    end
  end

  defp unknown_kwarg_error(comp_type, key, accepted) do
    {"`#{comp_type}()` does not accept `#{key}:`",
     "accepted keywords: #{Enum.map_join(accepted, ", ", &"`#{&1}:`")}"}
  end

  # Values of the REST options added as keywords. nil when valid, otherwise
  # the hint describing what is accepted.
  @route_types [:route, :ev_route]
  @lang ~r/\A[a-z]{2,3}\z/

  @flag_kwargs ~w(steps roundtrip verbal voice_instructions banner_instructions roundabout_exits)

  defp option_value_error(_type, key, {:bool, _, _}) when key in @flag_kwargs, do: nil
  defp option_value_error(_type, key, _value) when key in @flag_kwargs, do: "true or false"

  defp option_value_error(type, "annotations", {:bool, _, _}) when type in @route_types, do: nil

  defp option_value_error(type, "annotations", _value) when type in @route_types,
    do: "true or false: per-edge duration and distance arrays on the route"

  defp option_value_error(type, "overview", {:string, v, _})
       when type in @route_types and v in ~w(full simplified false),
       do: nil

  defp option_value_error(type, "overview", {:bool, false, _}) when type in @route_types, do: nil

  defp option_value_error(type, "overview", _value) when type in @route_types,
    do: ~s|"full" (default), "simplified" or false|

  defp option_value_error(type, "geometries", {:string, v, _})
       when type in @route_types and v in ~w(geojson polyline polyline6),
       do: nil

  defp option_value_error(type, "geometries", _value) when type in @route_types,
    do: ~s|"geojson" (default), "polyline" or "polyline6"|

  defp option_value_error(:isochrone, "denoise", {:number, n, _}) when n >= 0 and n <= 100,
    do: nil

  defp option_value_error(:isochrone, "denoise", _value),
    do: "a contour denoising level from 0 to 100"

  defp option_value_error(:isochrone, "generalize", {:number, n, _}) when n >= 0 and n <= 1000,
    do: nil

  defp option_value_error(:isochrone, "generalize", _value),
    do: "a simplification tolerance in meters, 0 to 1000"

  defp option_value_error(:matrix, "annotations", {:string, v, _}),
    do: matrix_annotations_error(String.split(v, ",", trim: true))

  defp option_value_error(:matrix, "annotations", {:list, items, _}) do
    if Enum.all?(items, &match?({:string, _, _}, &1)),
      do: matrix_annotations_error(for({:string, v, _} <- items, do: v)),
      else: ~s|"duration" and/or "distance"|
  end

  defp option_value_error(:matrix, "annotations", _value), do: ~s|"duration" and/or "distance"|

  defp option_value_error(:matrix, "fallback_speed", {:number, n, _}) when n > 0, do: nil

  defp option_value_error(:matrix, "fallback_speed", _value),
    do: "a speed in km/h above 0, used for pairs with no road path"

  defp option_value_error(:map_match, "radiuses", {:list, items, _}) do
    if Enum.all?(items, &match?({:number, n, _} when n > 0, &1)),
      do: nil,
      else: "a list of search radii in meters, one per trace point"
  end

  defp option_value_error(:map_match, "radiuses", _value),
    do: "a list of search radii in meters, one per trace point"

  # route()/ev_route() `lang` is a BCP 47 tag ("pt-BR"), checked against the
  # step languages in check_route_option/2.
  defp option_value_error(type, "lang", _value) when type in @route_types, do: nil

  defp option_value_error(_type, "lang", {:string, v, _}) do
    if Regex.match?(@lang, v), do: nil, else: ~s|a 2 or 3 letter language code, e.g. "de"|
  end

  defp option_value_error(_type, "lang", _value), do: ~s|a 2 or 3 letter language code, e.g. "de"|

  defp option_value_error(_type, "layer", {:string, v, _}) when v in @geocode_layers, do: nil

  defp option_value_error(_type, "layer", _value),
    do: "one layer: #{Enum.map_join(@geocode_layers, ", ", &inspect/1)}"

  defp option_value_error(:geocode, "addresses", {:list, [_ | _] = items, _}) do
    if length(items) <= 1000 and Enum.all?(items, &match?({:string, _, _}, &1)),
      do: nil,
      else: "a list of 1 to 1000 address strings"
  end

  defp option_value_error(:geocode, "addresses", _value), do: "a list of 1 to 1000 address strings"

  defp option_value_error(_type, _key, _value), do: nil

  defp matrix_annotations_error(names) do
    if Enum.all?(names, &(String.trim(&1) in ["duration", "distance"])),
      do: nil,
      else: ~s|"duration" and/or "distance"|
  end

  @reverse_geocode_includes ["census"]
  @traffic_models ["best_guess", "optimistic", "pessimistic"]
  # Languages Plaza translates turn-by-turn instructions into (POST /route
  # `lang`). A BCP 47 tag is accepted when its primary subtag is listed.
  @route_langs ~w(ar da de en es fi fr hi id it ja ko nb nl pl pt ru sv th tr vi zh)
  @route_lang_aliases %{"no" => "nb", "nn" => "nb", "in" => "id"}
  @route_units ["km", "mi"]
  @voice_units ["metric", "imperial", "km", "mi"]
  @route_exclusions ~w(toll ferry unpaved motorway trunk primary secondary tertiary)
  @centroid_metrics ["time", "distance"]
  @expansion_actions ["route", "isochrone", "matrix"]
  @expansion_properties ~w(duration distance cost cumulative_cost edge_id osm_way_id)

  defp check_computation_kwargs(:reverse_geocode, opts, pos) do
    Enum.flat_map(opts, fn
      {:kwarg, "include", {:string, value, _}} ->
        check_include_value(value, pos)

      {:kwarg, "include", {:list, items, _}} ->
        Enum.flat_map(items, fn
          {:string, value, _} -> check_include_value(value, pos)
          _ -> include_error("`include:` list items must be strings", pos)
        end)

      {:kwarg, "include", _} ->
        include_error("`include:` must be a string or a list of strings", pos)

      _ ->
        []
    end)
  end

  # route()/ev_route() options shared with Plaza's POST /route.
  defp check_computation_kwargs(comp_type, opts, pos) when comp_type in [:route, :ev_route] do
    Enum.flat_map(opts, &check_route_option(&1, pos))
  end

  # centroid() options shared with Plaza's POST /centroid.
  defp check_computation_kwargs(:centroid, opts, pos) do
    Enum.flat_map(opts, fn
      {:kwarg, "metric", {:string, metric, _}} when metric in @centroid_metrics ->
        []

      {:kwarg, "metric", _} ->
        route_option_error(
          "`metric:` must be one of #{Enum.map_join(@centroid_metrics, ", ", &inspect/1)}",
          "the total travel cost the meeting point minimises",
          pos
        )

      {:kwarg, "exclude", _} = opt ->
        check_route_option(opt, pos)

      _ ->
        []
    end)
  end

  # expansion() options shared with Plaza's POST /expansion.
  defp check_computation_kwargs(:expansion, opts, pos) do
    action_errors =
      case Enum.find(opts, &match?({:kwarg, "action", _}, &1)) do
        {:kwarg, "action", {:string, action, _}} when action in @expansion_actions ->
          []

        nil ->
          route_option_error(
            "`expansion()` requires `action:`",
            "one of #{Enum.map_join(@expansion_actions, ", ", &inspect/1)}",
            pos
          )

        _ ->
          route_option_error(
            "`action:` must be one of #{Enum.map_join(@expansion_actions, ", ", &inspect/1)}",
            "the request whose search to show",
            pos
          )
      end

    option_errors =
      Enum.flat_map(opts, fn
        {:kwarg, "expansion_properties", {:list, items, _}} ->
          Enum.flat_map(items, &check_expansion_property(&1, pos))

        {:kwarg, "expansion_properties", _} ->
          expansion_property_error("`expansion_properties:` must be a list of strings", pos)

        {:kwarg, "exclude", _} = opt ->
          check_route_option(opt, pos)

        _ ->
          []
      end)

    action_errors ++ option_errors
  end

  # geocode()/autocomplete() filters shared with POST /geocode,
  # /geocode/structured and /geocode/autocomplete.
  defp check_computation_kwargs(comp_type, opts, pos) when comp_type in [:geocode, :autocomplete] do
    Enum.flat_map(opts, &check_geocode_option(&1, pos))
  end

  # isochrone(mode: "transit", depart_at: ...): the same depart_at as route().
  defp check_computation_kwargs(:isochrone, opts, pos) do
    Enum.flat_map(opts, fn
      {:kwarg, "depart_at", _} = opt -> check_route_option(opt, pos)
      _ -> []
    end)
  end

  defp check_computation_kwargs(_comp_type, _opts, _pos), do: []

  # Values of the dataset keywords, shared with Plaza's REST `datasets`
  # (geocoding), `dataset_name_field` and `avoid_datasets` (routing): dataset
  # slugs or ids, which Plaza resolves and scope-checks. Which computations
  # take them is @computation_kwargs.
  @dataset_kwargs ~w(datasets dataset_name_field avoid_datasets)

  defp check_dataset_kwargs(opts, pos) do
    for {:kwarg, key, value} <- opts,
        key in @dataset_kwargs,
        error <- check_dataset_kwarg_value(key, value, pos),
        do: error
  end

  defp check_dataset_kwarg_value("dataset_name_field", {:string, _, _}, _pos), do: []

  defp check_dataset_kwarg_value("dataset_name_field", _value, pos),
    do:
      dataset_kwarg_error(
        "`dataset_name_field:` must be a string",
        "a property name, e.g. `\"title\"`",
        pos
      )

  defp check_dataset_kwarg_value(_key, {:string, _, _}, _pos), do: []

  defp check_dataset_kwarg_value(key, {:list, items, _}, pos) do
    if Enum.all?(items, &match?({:string, _, _}, &1)),
      do: [],
      else: dataset_kwarg_error("`#{key}:` list items must be strings", dataset_hint(), pos)
  end

  defp check_dataset_kwarg_value(key, _value, pos),
    do: dataset_kwarg_error("`#{key}:` must be a string or a list of strings", dataset_hint(), pos)

  defp dataset_hint(),
    do: ~s|dataset slugs or ids, or "plaza" / "all", e.g. `datasets: ["census-places"]`|

  defp dataset_kwarg_error(message, hint, pos),
    do: [%Error{line: pos.line, col: pos.col, message: message, hint: hint}]

  defp check_expansion_property({:string, value, _}, _pos) when value in @expansion_properties,
    do: []

  defp check_expansion_property({:string, value, _}, pos),
    do: expansion_property_error("unknown `expansion_properties:` value #{inspect(value)}", pos)

  defp check_expansion_property(_item, pos),
    do: expansion_property_error("`expansion_properties:` list items must be strings", pos)

  defp expansion_property_error(message, pos) do
    route_option_error(
      message,
      "supported: #{Enum.map_join(@expansion_properties, ", ", &inspect/1)}",
      pos
    )
  end

  # ── Geocoding ───────────────────────────────────────────────────

  @structured_components ~w(address neighbourhood locality county region postalcode country)
  @structured_required ~w(address locality region postalcode)
  @boundary_gid ~r/^osm:(way|relation):[1-9][0-9]{0,18}$/
  @gid ~r/^osm:(node|way|relation|address|place):[1-9][0-9]{0,18}$/
  @max_place_ids 50

  defp check_geocode_option({:kwarg, "layers", {:string, value, _}}, pos) do
    value
    |> String.split(",", trim: true)
    |> Enum.flat_map(&check_layer_value(String.trim(&1), pos))
  end

  defp check_geocode_option({:kwarg, "layers", {:list, items, _}}, pos) do
    Enum.flat_map(items, fn
      {:string, value, _} -> check_layer_value(value, pos)
      _ -> geocode_error("`layers:` list items must be strings", layers_hint(), pos)
    end)
  end

  defp check_geocode_option({:kwarg, "layers", _}, pos),
    do: geocode_error("`layers:` must be a string or a list of strings", layers_hint(), pos)

  defp check_geocode_option({:kwarg, "boundary_gid", {:string, gid, _}}, pos) do
    if Regex.match?(@boundary_gid, gid),
      do: [],
      else: geocode_error("invalid `boundary_gid:` #{inspect(gid)}", boundary_hint(), pos)
  end

  defp check_geocode_option({:kwarg, "boundary_gid", _}, pos),
    do: geocode_error("`boundary_gid:` must be a string", boundary_hint(), pos)

  defp check_geocode_option({:kwarg, "postalcode", {:number, _, _}}, _pos), do: []

  defp check_geocode_option({:kwarg, key, value}, pos) when key in @structured_components do
    case value do
      {:string, _, _} -> []
      _ -> geocode_error("`#{key}:` must be a string", nil, pos)
    end
  end

  defp check_geocode_option(_opt, _pos), do: []

  defp check_layer_value(value, _pos) when value in @geocode_layers, do: []

  defp check_layer_value(value, pos),
    do: geocode_error("unknown `layers:` value #{inspect(value)}", layers_hint(), pos)

  defp layers_hint(), do: "supported: #{Enum.map_join(@geocode_layers, ", ", &inspect/1)}"
  defp boundary_hint(), do: "a way or relation GID, e.g. `boundary_gid: \"osm:relation:62422\"`"

  # geocode() needs query text or a structured component; place_lookup()
  # needs 1-50 GIDs.
  defp check_computation_args(:geocode, args, opts, pos) do
    has_query =
      Enum.any?(args, &match?({:posarg, {:string, _, _}}, &1)) or
        Enum.any?(opts, &match?({:kwarg, key, _} when key in ["query", "addresses"], &1))

    has_component = Enum.any?(opts, &match?({:kwarg, key, _} when key in @structured_required, &1))

    if has_query or has_component,
      do: [],
      else:
        geocode_error(
          "`geocode()` needs an address string or one of `address:`, `locality:`, `region:`, `postalcode:`",
          ~s|e.g. `geocode("1600 Pennsylvania Ave, Washington DC")` or `geocode(address: "1600 Pennsylvania Ave", locality: "Washington", region: "DC")`|,
          pos
        )
  end

  defp check_computation_args(:place_lookup, args, opts, pos) do
    gid_args =
      for({:posarg, value} <- args, do: value) ++
        Enum.flat_map(opts, fn
          {:kwarg, "ids", {:list, items, _}} -> items
          {:kwarg, "ids", value} -> [value]
          _ -> []
        end)

    errors =
      Enum.flat_map(gid_args, fn
        {:string, gid, _} ->
          if Regex.match?(@gid, gid),
            do: [],
            else: geocode_error("invalid GID #{inspect(gid)}", gid_hint(), pos)

        _ ->
          geocode_error("`place_lookup()` takes GID strings", gid_hint(), pos)
      end)

    cond do
      gid_args == [] ->
        geocode_error("`place_lookup()` needs at least one GID", gid_hint(), pos)

      length(gid_args) > @max_place_ids ->
        geocode_error("`place_lookup()` takes at most #{@max_place_ids} GIDs", gid_hint(), pos)

      true ->
        errors
    end
  end

  defp check_computation_args(_comp_type, _args, _opts, _pos), do: []

  defp gid_hint(),
    do: ~s|GIDs look like "osm:node:123", "osm:way:456" or "osm:relation:789"|

  defp geocode_error(message, hint, pos),
    do: [%Error{line: pos.line, col: pos.col, message: message, hint: hint}]

  defp check_route_option({:kwarg, "depart_at", {:string, _, _}}, _pos), do: []

  defp check_route_option({:kwarg, "depart_at", _}, pos) do
    route_option_error(
      "`depart_at:` must be an ISO 8601 datetime string or \"now\"",
      "e.g. `depart_at: \"2026-03-16T08:00:00Z\"`",
      pos
    )
  end

  defp check_route_option({:kwarg, "traffic_model", {:string, model, _}}, _pos)
       when model in @traffic_models,
       do: []

  defp check_route_option({:kwarg, "traffic_model", _}, pos) do
    route_option_error(
      "`traffic_model:` must be one of #{Enum.map_join(@traffic_models, ", ", &inspect/1)}",
      "`traffic_model:` applies when `depart_at:` is set",
      pos
    )
  end

  defp check_route_option({:kwarg, "lang", {:string, tag, _}}, pos) do
    [primary | _subtags] = String.split(tag, ["-", "_"])
    primary = String.downcase(primary)

    if Map.get(@route_lang_aliases, primary, primary) in @route_langs,
      do: [],
      else: lang_error("unsupported `lang:` #{inspect(tag)}", pos)
  end

  defp check_route_option({:kwarg, "lang", _}, pos),
    do: lang_error(~s|`lang:` must be a language tag string such as "fr" or "pt-BR"|, pos)

  defp check_route_option({:kwarg, "units", {:string, units, _}}, _pos) when units in @route_units,
    do: []

  defp check_route_option({:kwarg, "units", _}, pos) do
    route_option_error(
      ~s|`units:` must be "km" or "mi"|,
      ~s|defaults to "mi" for US, GB, LR and MM `lang:` regions, otherwise "km"|,
      pos
    )
  end

  defp check_route_option({:kwarg, "voice_units", {:string, units, _}}, _pos)
       when units in @voice_units,
       do: []

  defp check_route_option({:kwarg, "voice_units", _}, pos) do
    route_option_error(
      ~s|`voice_units:` must be "metric" or "imperial"|,
      "distance units in voice announcements; defaults to `units:`",
      pos
    )
  end

  # One name per point (origin, each waypoint, destination); "" keeps the
  # default arrival instruction. Plaza checks the count.
  defp check_route_option({:kwarg, "waypoint_names", {:string, _, _}}, _pos), do: []

  defp check_route_option({:kwarg, "waypoint_names", {:list, items, _}}, pos) do
    if Enum.all?(items, &match?({:string, _, _}, &1)),
      do: [],
      else: waypoint_names_error(pos)
  end

  defp check_route_option({:kwarg, "waypoint_names", _}, pos), do: waypoint_names_error(pos)

  defp check_route_option({:kwarg, "exclude", {:string, value, _}}, pos) do
    value
    |> String.split(",", trim: true)
    |> Enum.flat_map(&check_exclude_value(&1, pos))
  end

  defp check_route_option({:kwarg, "exclude", {:list, items, _}}, pos) do
    Enum.flat_map(items, fn
      {:string, value, _} -> check_exclude_value(value, pos)
      _ -> exclude_error("`exclude:` list items must be strings", pos)
    end)
  end

  defp check_route_option({:kwarg, "exclude", _}, pos),
    do: exclude_error("`exclude:` must be a string or a list of strings", pos)

  defp check_route_option(_opt, _pos), do: []

  defp waypoint_names_error(pos) do
    route_option_error(
      "`waypoint_names:` must be a list of strings",
      ~s|one per point: origin, each waypoint, destination ("" for no name), or a ";"-separated string|,
      pos
    )
  end

  defp lang_error(message, pos),
    do: route_option_error(message, "supported: #{Enum.join(@route_langs, ", ")}", pos)

  defp check_exclude_value(value, _pos) when value in @route_exclusions, do: []

  defp check_exclude_value(value, pos),
    do: exclude_error("unknown `exclude:` value #{inspect(value)}", pos)

  defp exclude_error(message, pos) do
    route_option_error(
      message,
      "supported: #{Enum.map_join(@route_exclusions, ", ", &inspect/1)}",
      pos
    )
  end

  defp route_option_error(message, hint, pos),
    do: [%Error{line: pos.line, col: pos.col, message: message, hint: hint}]

  defp check_include_value(value, _pos) when value in @reverse_geocode_includes, do: []

  defp check_include_value(value, pos),
    do: include_error("unknown `include:` value #{inspect(value)} for `reverse_geocode()`", pos)

  defp include_error(message, pos) do
    supported = Enum.map_join(@reverse_geocode_includes, ", ", &inspect/1)

    [
      %Error{
        line: pos.line,
        col: pos.col,
        message: message,
        hint: "supported values: #{supported}"
      }
    ]
  end

  # ── Truck vehicle options ───────────────────────────────────────
  #
  # route(), isochrone() and matrix() with `mode: "truck"` take the vehicle
  # of Plaza's POST /route `truck` object as keywords. Plaza checks the
  # ranges (e.g. height at most 10 m); here only the shape.

  @truck_computations [:route, :isochrone, :matrix]
  @truck_dimensions ~w(height width length weight axle_load)
  @truck_kwargs @truck_dimensions ++ ~w(axle_count hazmat)
  @truck_hint ~s|e.g. `route(origin: ..., destination: ..., mode: "truck", height: 4.0, weight: 30, hazmat: true)`|

  defp check_truck_kwargs(comp_type, opts, pos) do
    case Enum.filter(opts, &match?({:kwarg, key, _} when key in @truck_kwargs, &1)) do
      [] ->
        []

      truck_opts ->
        check_truck_usage(comp_type, opts, pos) ++
          Enum.flat_map(truck_opts, &check_truck_value(&1, pos))
    end
  end

  # A mode that is not a literal (a variable, say) is checked by Plaza when
  # it runs; only a missing mode or a literal other than "truck" is an error.
  defp check_truck_usage(comp_type, opts, pos) when comp_type in @truck_computations do
    case Enum.find(opts, &match?({:kwarg, "mode", _}, &1)) do
      {:kwarg, "mode", {:string, "truck", _}} -> []
      {:kwarg, "mode", {literal, _, _}} when literal in [:string, :atom] -> truck_mode_error(pos)
      {:kwarg, "mode", _} -> []
      nil -> truck_mode_error(pos)
    end
  end

  defp check_truck_usage(comp_type, _opts, pos) do
    route_option_error(
      "`#{comp_type}()` has no truck options; they apply to `route()`, `isochrone()` and `matrix()` with `mode: \"truck\"`",
      @truck_hint,
      pos
    )
  end

  defp truck_mode_error(pos) do
    route_option_error(
      "truck options (#{Enum.map_join(@truck_kwargs, ", ", &"`#{&1}:`")}) need `mode: \"truck\"`",
      @truck_hint,
      pos
    )
  end

  defp check_truck_value({:kwarg, key, {:number, n, _}}, _pos)
       when key in @truck_dimensions and n > 0,
       do: []

  defp check_truck_value({:kwarg, key, _}, pos) when key in @truck_dimensions do
    unit = if key in ~w(height width length), do: "metres", else: "tonnes"
    route_option_error("`#{key}:` must be a positive number (#{unit})", @truck_hint, pos)
  end

  # Whole numbers only; `5.0` counts, as in the LSP and in Plaza.
  defp check_truck_value({:kwarg, "axle_count", {:number, n, _}}, _pos)
       when n > 0 and n == trunc(n),
       do: []

  defp check_truck_value({:kwarg, "axle_count", _}, pos),
    do: route_option_error("`axle_count:` must be a whole number of axles", @truck_hint, pos)

  defp check_truck_value({:kwarg, "hazmat", {:bool, _, _}}, _pos), do: []

  defp check_truck_value({:kwarg, "hazmat", _}, pos),
    do: route_option_error("`hazmat:` must be `true` or `false`", @truck_hint, pos)

  # route() and isochrone() with `mode: "transit"` (Plaza's pedestrian +
  # public transit routing) take its options as keywords. Plaza checks the
  # upper bounds (max_walk_m, max_transfers); here the shape and the 0-1
  # preference range.

  @transit_computations [:route, :isochrone]
  @transit_preferences ~w(use_bus use_rail use_transfers)
  @transit_hint ~s|e.g. `route(origin: ..., destination: ..., mode: "transit", depart_at: "2026-03-16T08:00:00-04:00", max_walk_m: 800)`|

  defp check_transit_kwargs(comp_type, opts, pos) do
    case Enum.filter(opts, &match?({:kwarg, key, _} when key in @transit_option_kwargs, &1)) do
      [] ->
        []

      transit_opts ->
        check_transit_usage(comp_type, opts, pos) ++
          Enum.flat_map(transit_opts, &check_transit_value(&1, pos))
    end
  end

  # As for truck options: a mode that is not a literal is checked by Plaza.
  defp check_transit_usage(comp_type, opts, pos) when comp_type in @transit_computations do
    case Enum.find(opts, &match?({:kwarg, "mode", _}, &1)) do
      {:kwarg, "mode", {:string, "transit", _}} -> []
      {:kwarg, "mode", {literal, _, _}} when literal in [:string, :atom] -> transit_mode_error(pos)
      {:kwarg, "mode", _} -> []
      nil -> transit_mode_error(pos)
    end
  end

  defp check_transit_usage(comp_type, _opts, pos) do
    route_option_error(
      "`#{comp_type}()` has no transit options; they apply to `route()` and `isochrone()` with `mode: \"transit\"`",
      @transit_hint,
      pos
    )
  end

  defp transit_mode_error(pos) do
    route_option_error(
      "transit options (#{Enum.map_join(@transit_option_kwargs, ", ", &"`#{&1}:`")}) need `mode: \"transit\"`",
      @transit_hint,
      pos
    )
  end

  defp check_transit_value({:kwarg, key, {:number, n, _}}, _pos)
       when key in @transit_preferences and n >= 0 and n <= 1,
       do: []

  defp check_transit_value({:kwarg, key, _}, pos) when key in @transit_preferences,
    do:
      route_option_error(
        "`#{key}:` must be a number from 0 to 1",
        "0 never uses it; 1 (default) has no penalty",
        pos
      )

  defp check_transit_value({:kwarg, "max_walk_m", {:number, n, _}}, _pos) when n >= 0, do: []

  defp check_transit_value({:kwarg, "max_walk_m", _}, pos),
    do:
      route_option_error(
        "`max_walk_m:` must be a non-negative number of meters",
        "the longest walk to, between and from stops",
        pos
      )

  # Whole numbers only; `2.0` counts, as in the LSP and in Plaza.
  defp check_transit_value({:kwarg, "max_transfers", {:number, n, _}}, _pos)
       when n >= 0 and n == trunc(n),
       do: []

  defp check_transit_value({:kwarg, "max_transfers", _}, pos),
    do:
      route_option_error(
        "`max_transfers:` must be a whole number",
        "the most changes between vehicles",
        pos
      )

  # ── AST position extraction ───────────────────────────────────────

  defp pos_map(node) when is_tuple(node) do
    last = :erlang.element(tuple_size(node), node)
    if is_map(last), do: last, else: %{}
  end

  # z/x/y of a slippy-map tile: 0 <= x, y < 2^z
  @max_tile_zoom 22

  defp check_tile_coords(z, x, y, pos) do
    cond do
      z < 0 or z > @max_tile_zoom ->
        [
          %Error{
            line: pos.line,
            col: pos.col,
            message: "`.tile()` zoom must be between 0 and #{@max_tile_zoom}, got #{z}",
            hint: "the server serves zoom levels its tile endpoint documents"
          }
        ]

      x < 0 or y < 0 or x >= Bitwise.bsl(1, z) or y >= Bitwise.bsl(1, z) ->
        [
          %Error{
            line: pos.line,
            col: pos.col,
            message:
              "`.tile(#{z}, #{x}, #{y})` is outside the grid: x and y must be between 0 and #{Bitwise.bsl(1, z) - 1} at zoom #{z}",
            hint: "x and y are slippy-map tile coordinates"
          }
        ]

      true ->
        []
    end
  end

  defp check_tile_kwarg({"layers", {:list, items, _}}, pos) do
    if items != [] and Enum.all?(items, &match?({:string, _, _}, &1)),
      do: [],
      else: [tile_layers_error(pos)]
  end

  defp check_tile_kwarg({"layers", {:string, _, _}}, _pos), do: []
  defp check_tile_kwarg({"layers", _}, pos), do: [tile_layers_error(pos)]

  defp check_tile_kwarg({key, _}, pos) do
    [
      %Error{
        line: pos.line,
        col: pos.col,
        message: "unknown `.tile()` argument `#{key}:`",
        hint: "`.tile(z, x, y)` takes one keyword argument, `layers: [\"pois\", ...]`"
      }
    ]
  end

  defp tile_layers_error(pos) do
    %Error{
      line: pos.line,
      col: pos.col,
      message: "`.tile()` `layers:` must be a non-empty list of layer names",
      hint: "e.g., `layers: [\"pois\", \"buildings\"]`"
    }
  end
end
