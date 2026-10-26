defmodule PlazaQL.Compiler do
  @moduledoc """
  Compiles PlazaQL AST into `PlazaQL.Plan` structs.

  Transforms parsed (and optionally type-checked) AST nodes into the unified
  Plan IR that a query executor can run.
  """

  alias PlazaQL.Error
  alias PlazaQL.GeometryRef
  alias PlazaQL.Plan
  alias PlazaQL.Plan.OutputOptions

  require Logger

  @known_atoms Map.new(
                 ~w(asc auto bbox bicycle car center count csv desc destination
                    distance down down_full foot geojson geometry json limit mode
                    node nwr origin point profile query qt radius relation role
                    time truck type up up_full way xml)a,
                 &{Atom.to_string(&1), &1}
               )

  @max_osm_ids 10_000

  # Sort modes: `.sort(by: :osm_id)`, `.sort(:name)`, ...
  @sort_atoms [:osm_id, :name, :distance, :qt]

  # Inline set expressions a spatial predicate can take as its geometry.
  @inline_sets [:boundary, :computation, :search]

  # Predicate spatial methods
  @predicate_methods ~w(within intersects contains crosses touches not_within not_intersects not_contains)a
  @max_datasets 20

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @type compile_result :: %{
          plans: [Plan.t()],
          steps: [{String.t(), Plan.t()}],
          output_names: [String.t() | nil]
        }

  @doc """
  Compile a list of AST nodes into Plan IR.

  Returns `{:ok, compile_result()}` with plans, named steps, and output names,
  or `{:error, [Error.t()]}` on compilation failure.

  ## Options

    * `:user_id` — the user ID for scoping (passed through to plan context)
    * `:schema` — a `PlazaQL.Schema` struct; limits are read from `schema.limits`
  """
  @spec compile([term()], keyword()) :: {:ok, compile_result()} | {:error, [Error.t()]}
  def compile(ast, opts \\ []) when is_list(ast) do
    schema = Keyword.get(opts, :schema)
    max_ids = if schema, do: schema.limits[:max_osm_ids] || @max_osm_ids, else: @max_osm_ids

    env = %{
      steps: [],
      plans: [],
      output_names: [],
      variables: %{},
      directives: [],
      user_id: Keyword.get(opts, :user_id),
      max_osm_ids: max_ids
    }

    result =
      ast
      |> inline_geometry_variables()
      |> hoist_inline_sets()
      |> Enum.reduce(env, &process_top_level/2)

    plans = Enum.reverse(result.plans)

    steps = Enum.reverse(result.steps)
    output_names = Enum.reverse(result.output_names)

    {:ok, %{plans: plans, steps: steps, output_names: output_names}}
  catch
    {:compile_error, %Error{} = error} -> {:error, [error]}
  end

  # ── Inline geometry sets ──────────────────────────────────────────

  # `.within(boundary(name: "X"))`, `.within(isochrone(...))`,
  # `.intersects(search(...))` and the other predicates: the inline expression
  # must run to supply the geometry, exactly like
  # `$b = boundary(name: "X"); ... .within($b)`. Hoist each one into such a
  # step (named `boundary#N`, `computation#N`, `search#N`, which no PlazaQL
  # identifier can collide with) so it resolves the same way.
  defp hoist_inline_sets(ast) do
    {nodes, _count} =
      Enum.flat_map_reduce(ast, 0, fn node, count ->
        {node, {hoisted, count}} = hoist(node, {[], count})
        {Enum.reverse(hoisted) ++ [node], count}
      end)

    nodes
  end

  # `#within(boundary(...))`: the directive's geometry is hoisted the same
  # way, so every search it scopes filters by the boundary's polygon.
  defp hoist({:directive, name, args, dpos}, acc) when name in @predicate_methods do
    {{:method, ^name, args, _}, acc} = hoist({:method, name, args, dpos}, acc)
    {{:directive, name, args, dpos}, acc}
  end

  defp hoist({:directive, _, _, _} = node, acc), do: {node, acc}

  defp hoist({:method, name, [{:posarg, geom}], mpos}, acc)
       when name in @predicate_methods and elem(geom, 0) in @inline_sets do
    hoist_geometry(name, geom, mpos, acc)
  end

  defp hoist({:method, name, [{:kwarg, "geometry", geom}], mpos}, acc)
       when name in @predicate_methods and elem(geom, 0) in @inline_sets do
    hoist_geometry(name, geom, mpos, acc)
  end

  defp hoist(tuple, acc) when is_tuple(tuple) do
    {items, acc} =
      tuple
      |> Tuple.to_list()
      |> Enum.map_reduce(acc, &hoist/2)

    {List.to_tuple(items), acc}
  end

  defp hoist(list, acc) when is_list(list), do: Enum.map_reduce(list, acc, &hoist/2)
  defp hoist(other, acc), do: {other, acc}

  defp hoist_geometry(name, geom, mpos, {hoisted, count}) do
    # Hoist anything nested in the inline expression first.
    {geom, {hoisted, count}} = hoist(geom, {hoisted, count})
    count = count + 1
    pos = elem(geom, tuple_size(geom) - 1)
    var = "$#{elem(geom, 0)}##{count}"
    step = {:var_assign, var, geom, pos}
    {{:method, name, [{:posarg, {:var_ref, var, pos}}], mpos}, {[step | hoisted], count}}
  end

  # ── Geometry variables ────────────────────────────────────────────

  # `$z = polygon(...)` (or point, linestring, bbox, circle, or a number such
  # as `$radius = 1000`) holds a literal, not a set to run: each later `$z` is
  # replaced by the literal, so `.within($z)` compiles exactly like
  # `.within(polygon(...))`.
  @geometry_literals [:point, :linestring, :polygon, :bbox, :circle, :number]

  defp inline_geometry_variables(ast) do
    {nodes, _literals} =
      Enum.flat_map_reduce(ast, %{}, fn
        {:var_assign, "$" <> _ = var, geom, _pos}, literals
        when elem(geom, 0) in @geometry_literals ->
          {[], Map.put(literals, var, substitute_literals(geom, literals))}

        node, literals ->
          {[substitute_literals(node, literals)], literals}
      end)

    nodes
  end

  defp substitute_literals({:var_ref, var, _pos} = ref, literals),
    do: Map.get(literals, var, ref)

  # distance($p) with `$p = point(...)` measures from that point, like
  # distance(point(...)); other literals have no distance form.
  defp substitute_literals({:geom_func, :distance, {:set_ref, name}, pos} = node, literals) do
    case Map.get(literals, "$" <> name) do
      nil ->
        node

      {:point, lat, lng, _} when is_number(lat) and is_number(lng) ->
        {:geom_func, :distance, {lat, lng}, pos}

      _other ->
        throw(
          {:compile_error,
           %Error{
             message: "distance($#{name}) needs a point or a variable holding features",
             hint: "use distance(point(lat, lng)), or assign `$#{name}` a search or computation",
             line: pos[:line] || 0,
             col: pos[:col] || 0
           }}
        )
    end
  end

  defp substitute_literals(tuple, literals) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&substitute_literals(&1, literals))
    |> List.to_tuple()
  end

  defp substitute_literals(list, literals) when is_list(list),
    do: Enum.map(list, &substitute_literals(&1, literals))

  defp substitute_literals(other, _literals), do: other

  # ── Top-level node processing ─────────────────────────────────────

  defp process_top_level({:var_assign, "$" <> name, expr, _pos}, env) do
    plan = compile_expr(expr, env)
    %{env | steps: [{name, plan} | env.steps], variables: Map.put(env.variables, name, plan)}
  end

  defp process_top_level({:output, name, expr, _pos}, env) do
    plan = compile_expr(expr, env)

    env = %{env | plans: [plan | env.plans], output_names: [name | env.output_names]}

    # Named outputs ($$.name) are also referenceable as variables in later statements
    if name do
      %{env | variables: Map.put(env.variables, "$$." <> name, plan)}
    else
      env
    end
  end

  defp process_top_level({:bare_output, expr, _pos}, env) do
    plan = compile_expr(expr, env)
    %{env | plans: [plan | env.plans], output_names: [nil | env.output_names]}
  end

  defp process_top_level({:directive, method_name, args, pos}, env) do
    %{env | directives: env.directives ++ [{method_name, args, pos}]}
  end

  defp process_top_level(node, env) do
    Logger.warning("PlazaQL compiler: ignoring unknown top-level node: #{inspect(node)}")
    env
  end

  # ── Expression compilation ────────────────────────────────────────

  defp compile_expr({:search, {:dataset, slugs}, filters, methods, _pos}, env) do
    compiled_filters = Enum.map(filters, &compile_tag_filter/1)
    sources = validate_dataset_slugs(slugs)

    %Plan{
      element_types: [],
      tag_filters: compiled_filters,
      sources: sources
    }
    |> apply_directives(env.directives, env)
    |> apply_methods(methods, env)
  end

  defp compile_expr({:search, type, filters, methods, _pos}, env) do
    {id_filters, tag_filters} = Enum.split_with(filters, &id_filter?/1)
    compiled_filters = Enum.map(tag_filters, &compile_tag_filter/1)
    osm_ids = extract_osm_ids(id_filters, env)

    %Plan{
      element_types: expand_element_type(type),
      tag_filters: compiled_filters,
      osm_ids: if(osm_ids == [], do: nil, else: osm_ids)
    }
    |> apply_directives(env.directives, env)
    |> apply_methods(methods, env)
  end

  defp compile_expr({:boundary, filters, _pos}, env) do
    plan = %Plan{element_types: [:boundary], tag_filters: filters}

    case find_within_geometry(env.directives) do
      nil -> plan
      geom -> %{plan | scope_geometry: geom}
    end
  end

  defp compile_expr({:computation, comp_type, args, opts, pos}, env) do
    params = at_position(pos, fn -> compile_computation_params(comp_type, args, opts, env) end)
    %Plan{kind: :computation, element_types: [], computation: {comp_type, params}}
  end

  defp compile_expr({:union, left, right, _pos}, env) do
    left_plan = compile_expr(left, env)
    right_plan = compile_expr(right, env)
    %{left_plan | set_ops: left_plan.set_ops ++ [{:union, right_plan}]}
  end

  defp compile_expr({:difference, left, right, _pos}, env) do
    left_plan = compile_expr(left, env)
    right_plan = compile_expr(right, env)
    %{left_plan | set_ops: left_plan.set_ops ++ [{:difference, [left_plan, right_plan]}]}
  end

  defp compile_expr({:intersection, left, right, _pos}, env) do
    left_plan = compile_expr(left, env)
    right_plan = compile_expr(right, env)
    %{left_plan | set_ops: left_plan.set_ops ++ [{:intersection, right_plan}]}
  end

  defp compile_expr({:chain, receiver, method}, env) do
    plan = compile_expr(receiver, env)
    apply_method(plan, method, env)
  end

  defp compile_expr({:chain, receiver, method, _meta}, env) do
    plan = compile_expr(receiver, env)
    apply_method(plan, method, env)
  end

  defp compile_expr({:var_ref, "$" <> name, _pos}, env) do
    Map.get(env.variables, name, %Plan{})
  end

  defp compile_expr({:output_var_ref, name, _pos}, env) do
    Map.get(env.variables, "$$." <> name, %Plan{})
  end

  # `$z = point(...); $z;` or a bare `point(...);`: a shape is an argument,
  # not a query.
  defp compile_expr(geom, _env) when elem(geom, 0) in @geometry_literals do
    pos = elem(geom, tuple_size(geom) - 1)
    kind = if elem(geom, 0) == :number, do: "number", else: "#{elem(geom, 0)}(...)"

    throw(
      {:compile_error,
       %Error{
         message:
           "a #{kind} is a value, not a query to output; use it as an argument, e.g. `search(...).within(...)`, `.around(...)` or `route(origin: ...)`",
         line: Map.get(pos, :line, 0),
         col: Map.get(pos, :col, 0)
       }}
    )
  end

  defp compile_expr(expr, _env) do
    throw(
      {:compile_error,
       %Error{message: "unknown expression node: #{inspect(expr)}", line: 0, col: 0}}
    )
  end

  defp find_within_geometry(directives) do
    Enum.find_value(directives, fn
      {:within, args, _pos} -> {:predicate, :within, extract_geometry_arg(args)}
      _ -> nil
    end)
  end

  # ── Method application ────────────────────────────────────────────

  defp apply_methods(plan, methods, env) do
    Enum.reduce(methods, plan, fn method, acc ->
      at_position(method_pos(method), fn -> apply_method(acc, method, env) end)
    end)
  end

  defp method_pos({:method, _name, _args, pos}), do: pos
  defp method_pos({:method, _name, _expr, _order, pos}), do: pos
  defp method_pos(_method), do: nil

  # Errors thrown below know what is wrong but not where; give them the
  # position of the method or computation they came from.
  defp at_position(%{line: line, col: col}, fun) when is_integer(line) do
    fun.()
  catch
    {:compile_error, %Error{line: 0} = error} ->
      throw({:compile_error, %{error | line: line, col: col}})
  end

  defp at_position(_pos, fun), do: fun.()

  defp apply_directives(plan, [], _env), do: plan

  defp apply_directives(plan, directives, env) do
    Enum.reduce(directives, plan, fn {method_name, args, pos}, acc ->
      at_position(pos, fn -> apply_method(acc, {:method, method_name, args, pos}, env) end)
    end)
  end

  # -- Spatial methods --

  # `.around(distance, geometry)`, positional or as `distance:` / `geometry:`.
  defp apply_method(plan, {:method, :around, args, _pos}, _env) do
    case args do
      [{:posarg, {:number, distance, _}}, {:posarg, geom}] ->
        add_spatial(plan, around_filter(distance, geom))

      [{:kwarg, "distance", {:number, distance, _}}, {:kwarg, "geometry", geom}] ->
        add_spatial(plan, around_filter(distance, geom))

      other ->
        around_error!(other)
    end
  end

  defp apply_method(plan, {:method, :bbox, args, _pos}, _env) do
    case args do
      [
        {:posarg, {:number, s, _}},
        {:posarg, {:number, w, _}},
        {:posarg, {:number, n, _}},
        {:posarg, {:number, e, _}}
      ] ->
        add_spatial(plan, {:bbox, s, w, n, e})

      kwargs when length(kwargs) == 4 ->
        add_spatial(plan, bbox_from_keywords(kwargs))

      other ->
        argument_error!("bbox(south, west, north, east) numbers", other)
    end
  end

  defp apply_method(plan, {:method, :h3, args, _pos}, _env) do
    case args do
      [{:posarg, {:string, cell, _}}] -> add_spatial(plan, {:h3, cell})
      other -> argument_error!("an H3 cell string", other)
    end
  end

  defp apply_method(plan, {:method, method_name, args, _pos}, _env)
       when method_name in @predicate_methods do
    geometry = extract_geometry_arg(args)

    add_spatial(plan, {:predicate, method_name, geometry})
  end

  # -- Transform methods --

  defp apply_method(plan, {:method, :buffer, args, _pos}, _env) do
    value = extract_single_number(args)
    opts = ensure_output_options(plan)
    %{plan | output_options: %{opts | buffer: value / 1}}
  end

  defp apply_method(plan, {:method, :simplify, args, _pos}, _env) do
    value = extract_single_number(args)
    opts = ensure_output_options(plan)
    %{plan | output_options: %{opts | simplify: value / 1}}
  end

  defp apply_method(plan, {:method, :centroid, _args, _pos}, _env) do
    opts = ensure_output_options(plan)
    %{plan | output_options: %{opts | centroid: true}}
  end

  defp apply_method(plan, {:method, :precision, args, _pos}, _env) do
    value = extract_single_number(args)
    opts = ensure_output_options(plan)
    %{plan | output_options: %{opts | precision: trunc(value)}}
  end

  defp apply_method(plan, {:method, :fields, args, _pos}, _env) do
    fields = extract_string_list(args)
    opts = ensure_output_options(plan)
    %{plan | output_options: %{opts | fields: fields}}
  end

  defp apply_method(plan, {:method, :include, args, _pos}, _env) do
    items = Enum.map(args, &include_item!/1)
    opts = ensure_output_options(plan)
    %{plan | output_options: %{opts | include: MapSet.new(items)}}
  end

  # .geometry(false) drops each feature's geometry (REST `output.geometry`).
  defp apply_method(plan, {:method, :geometry, [{:posarg, {:bool, keep?, _}}], _pos}, _env) do
    opts = ensure_output_options(plan)
    %{plan | output_options: %{opts | geometry: keep?}}
  end

  defp apply_method(_plan, {:method, :geometry, args, _pos}, _env) do
    throw(
      {:compile_error,
       %Error{
         message: "`.geometry()` takes true or false, got #{inspect(args)}",
         line: 0,
         col: 0
       }}
    )
  end

  defp apply_method(plan, {:method, :sort, args, _pos}, _env) do
    value = extract_sort_value(args)
    opts = ensure_output_options(plan)
    %{plan | output_options: %{opts | sort: value}}
  end

  defp apply_method(_plan, {:method, :sort_expr, {:string, value, _}, _order, _pos}, _env) do
    throw(
      {:compile_error,
       %Error{
         message:
           "`.sort(#{inspect(value)})` sorts by a constant string; " <>
             ~s|use `.sort(t["#{value}"])` for a tag, or `.sort(by: :osm_id)`, `.sort(by: :name)`, `.sort(by: :qt)`|,
         line: 0,
         col: 0
       }}
    )
  end

  # `.sort(:osm_id)` is `.sort(by: :osm_id)`; other atoms would sort by a
  # constant.
  defp apply_method(plan, {:method, :sort_expr, {:atom, mode, _}, _order, _pos}, _env)
       when mode in @sort_atoms do
    opts = ensure_output_options(plan)
    %{plan | output_options: %{opts | sort: mode}}
  end

  defp apply_method(_plan, {:method, :sort_expr, {:atom, _, _} = atom, _order, _pos}, _env),
    do: sort_mode_error!(atom)

  defp apply_method(plan, {:method, :sort_expr, expr, order, _pos}, _env) do
    %{plan | sort_expr: {expr, order}}
  end

  # -- Ordering methods --

  defp apply_method(plan, {:method, :limit, args, _pos}, _env) do
    %{plan | limit: trunc(extract_single_number(args))}
  end

  defp apply_method(plan, {:method, :offset, args, _pos}, _env) do
    %{plan | offset: trunc(extract_single_number(args))}
  end

  defp apply_method(plan, {:method, :cursor, args, _pos}, _env) do
    case extract_single_value(args) do
      {:string, token, _} -> %{plan | cursor: token}
      other -> argument_error!("a cursor string", other)
    end
  end

  # -- Output mode methods --

  defp apply_method(plan, {:method, :count, _args, _pos}, _env), do: %{plan | output_mode: :count}
  defp apply_method(plan, {:method, :ids, _args, _pos}, _env), do: %{plan | output_mode: :ids}
  defp apply_method(plan, {:method, :tags, _args, _pos}, _env), do: %{plan | output_mode: :tags}
  defp apply_method(plan, {:method, :skel, _args, _pos}, _env), do: %{plan | output_mode: :skel}
  defp apply_method(plan, {:method, :geom, _args, _pos}, _env), do: %{plan | output_mode: :full}

  # .tile(z, x, y, layers: [...]) — arguments are validated by the type checker
  defp apply_method(plan, {:method, :tile, args, _pos}, _env) do
    [z, x, y] = for {:posarg, {:number, n, _}} <- args, do: n

    layers =
      Enum.find_value(args, fn
        {:kwarg, "layers", {:list, items, _}} -> Enum.map(items, fn {:string, s, _} -> s end)
        {:kwarg, "layers", {:string, s, _}} -> String.split(s, ",", trim: true)
        _ -> nil
      end)

    %{plan | output_mode: :tile, tile: %{z: z, x: x, y: y, layers: layers}}
  end

  # -- Computed column methods --

  defp apply_method(plan, {:method, :elevation, _args, _pos}, _env) do
    %{
      plan
      | computed_columns: plan.computed_columns ++ [{:elevation_m, {:geom_func, :elevation, nil}}]
    }
  end

  defp apply_method(plan, {:method, :length, _args, _pos}, _env) do
    %{plan | computed_columns: plan.computed_columns ++ [{:length_m, {:geom_func, :length, nil}}]}
  end

  defp apply_method(plan, {:method, :area, _args, _pos}, _env) do
    %{plan | computed_columns: plan.computed_columns ++ [{:area_m2, {:geom_func, :area, nil}}]}
  end

  defp apply_method(plan, {:method, :distance, args, _pos}, _env) do
    case args do
      [{:posarg, {:point, lat, lng, _}}] ->
        %{
          plan
          | computed_columns:
              plan.computed_columns ++ [{:distance_m, {:geom_func, :distance, {lat, lng}, nil}}]
        }

      _ ->
        plan
    end
  end

  defp apply_method(plan, {:method, :overlap_fraction, args, _pos}, _env) do
    ref =
      case args do
        [{:posarg, geom}] -> GeometryRef.from_ast(geom)
        _ -> :error
      end

    case ref do
      {:ok, ref} ->
        column = {:overlap_fraction, {:geom_func, :overlap_fraction, ref, nil}}
        %{plan | computed_columns: plan.computed_columns ++ [column]}

      :error ->
        throw(
          {:compile_error,
           %Error{
             message:
               "`.overlap_fraction()` expects a polygon(...), bbox(...), or a variable holding polygons",
             line: 0,
             col: 0
           }}
        )
    end
  end

  # -- Recurse --

  defp apply_method(plan, {:method, :expand, args, _pos}, _env) do
    direction =
      case args do
        [] ->
          :down

        [{:posarg, {:atom, dir, _}}] when dir in [:down, :up, :down_full, :up_full] ->
          dir

        [{:kwarg, "direction", {:atom, dir, _}}] when dir in [:down, :up, :down_full, :up_full] ->
          dir

        other ->
          argument_error!(":down, :up, :down_full or :up_full", other)
      end

    %{plan | recurse: direction}
  end

  # -- Filter method --

  defp apply_method(plan, {:method, :filter, filters, _pos}, _env) do
    compiled = Enum.map(filters, &compile_tag_filter/1)
    %{plan | tag_filters: plan.tag_filters ++ compiled}
  end

  # -- Expression filter method --

  defp apply_method(plan, {:method, :filter_expr, expr, _pos}, _env) do
    %{plan | filter_exprs: plan.filter_exprs ++ [expr]}
  end

  # -- Aggregation methods --

  @aggregation_modes [:sum, :min, :max, :avg]

  defp apply_method(plan, {:method, mode, expr, _pos}, _env) when mode in @aggregation_modes do
    %{plan | output_mode: mode, aggregate_expr: expr}
  end

  # -- Group by --

  defp apply_method(plan, {:method, :group_by, expr, _pos}, _env) do
    %{plan | group_by: expr}
  end

  # -- Join methods --

  defp apply_method(plan, {:method, :member_of, args, _pos}, env) do
    {source, role} = extract_join_args(args, env)
    source_type = infer_source_element_type(source)
    target_type = List.first(plan.element_types)
    %{plan | member_filter: {:member_of, target_type, source_type, source, role}}
  end

  defp apply_method(plan, {:method, :has_member, args, _pos}, env) do
    {source, role} = extract_join_args(args, env)
    source_type = infer_source_element_type(source)
    target_type = List.first(plan.element_types)
    %{plan | member_filter: {:has_member, target_type, source_type, source, role}}
  end

  # -- Narrowing methods --

  defp apply_method(plan, {:method, :first, _args, _pos}, _env) do
    %{plan | narrow: :first, limit: 1}
  end

  defp apply_method(plan, {:method, :last, _args, _pos}, _env) do
    %{plan | narrow: :last}
  end

  defp apply_method(plan, {:method, :index, args, _pos}, _env) do
    n = extract_single_number(args)
    %{plan | narrow: {:index, n}, limit: 1, offset: max(n - 1, 0)}
  end

  # -- Unknown method: pass through --

  defp apply_method(_plan, {:method, name, _args, _pos}, _env) do
    throw({:compile_error, %Error{message: "unknown method: #{inspect(name)}", line: 0, col: 0}})
  end

  # ── Element type expansion ────────────────────────────────────────

  @all_types [:node, :way, :relation]

  defp expand_element_type(nil), do: @all_types
  defp expand_element_type(:nwr), do: @all_types
  defp expand_element_type(:node), do: [:node]
  defp expand_element_type(:way), do: [:way]
  defp expand_element_type(:relation), do: [:relation]

  # ── Tag filter compilation ────────────────────────────────────────

  defp compile_tag_filter({:bracket_ref_eq, key, {:bracket_ref, var_name, attr, _pos}}) do
    set_name =
      case var_name do
        "$$." <> rest -> "$$.#{rest}"
        "$" <> rest -> rest
        other -> other
      end

    {:bracket_eq, key, set_name, attr}
  end

  # Convert numeric equality to string form for non-id keys (tags are stored as strings)
  defp compile_tag_filter({:eq_num, key, number}), do: {:eq, key, to_string(number)}

  defp compile_tag_filter({:eq_list, key, _numbers}) do
    throw(
      {:compile_error,
       %Error{
         message: "list values are only supported for id filters, got key: #{inspect(key)}",
         line: 0,
         col: 0
       }}
    )
  end

  defp compile_tag_filter(filter), do: filter

  # ── ID filter helpers ───────────────────────────────────────

  defp id_filter?({:eq, "id", _}), do: true
  defp id_filter?({:eq_num, "id", _}), do: true
  defp id_filter?({:eq_list, "id", _}), do: true
  defp id_filter?(_), do: false

  defp extract_osm_ids(filters, env) do
    max = Map.get(env, :max_osm_ids, @max_osm_ids)

    ids =
      Enum.flat_map(filters, fn
        {:eq, "id", val} -> [parse_id(val)]
        {:eq_num, "id", n} -> [trunc(n)]
        {:eq_list, "id", nums} -> Enum.map(nums, &trunc/1)
        _ -> []
      end)
      |> Enum.reject(&is_nil/1)

    if length(ids) > max do
      throw({:compile_error, %Error{message: "too many IDs (max #{max})", line: 0, col: 0}})
    end

    ids
  end

  defp parse_id(val) when is_integer(val), do: val
  defp parse_id(val) when is_float(val), do: trunc(val)

  defp parse_id(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  # ── Join argument helpers ────────────────────────────────────────

  defp extract_join_args(args, env) do
    source =
      case Enum.find(args, &match?({:posarg, _}, &1)) do
        {:posarg, {:var_ref, "$" <> name, _pos}} -> name
        {:posarg, {:output_var_ref, name, _pos}} -> "$$.#{name}"
        {:posarg, expr} -> compile_expr(expr, env)
        nil -> %Plan{}
      end

    role =
      case Enum.find(args, &match?({:kwarg, "role", _}, &1)) do
        {:kwarg, "role", {:string, s, _}} -> s
        {:kwarg, "role", {:identifier, s, _}} -> s
        _ -> nil
      end

    {source, role}
  end

  defp infer_source_element_type(%Plan{element_types: [type | _]}), do: type
  defp infer_source_element_type(%Plan{}), do: :relation
  defp infer_source_element_type(_name), do: :relation

  # ── Argument extraction helpers ───────────────────────────────────

  defp extract_single_number(args) do
    case extract_single_value(args) do
      {:number, n, _} -> n
      other -> argument_error!("a number", other)
    end
  end

  @spec argument_error!(String.t(), term()) :: no_return()
  defp argument_error!(expected, got) do
    throw(
      {:compile_error,
       %Error{message: "expected #{expected}, got #{inspect(got)}", line: 0, col: 0}}
    )
  end

  defp extract_string_list(args) do
    Enum.flat_map(args, fn
      {:posarg, {:string, s, _}} -> [s]
      {:posarg, {:identifier, s, _}} -> [s]
      {:kwarg, _, {:string, s, _}} -> [s]
      other -> argument_error!("field names as strings", other)
    end)
  end

  # `.include()` extras, the same set as REST `output.include`.
  @include_items %{"bbox" => :bbox, "center" => :center, "distance" => :distance}

  defp include_item!({:posarg, {tag, value, _}} = arg) when tag in [:string, :atom] do
    case Map.fetch(@include_items, to_string(value)) do
      {:ok, item} -> item
      :error -> include_error!(arg)
    end
  end

  defp include_item!(arg), do: include_error!(arg)

  @spec include_error!(term()) :: no_return()
  defp include_error!(arg) do
    throw(
      {:compile_error,
       %Error{
         message: ~s|`.include()` takes "bbox", "center" or "distance", got #{inspect(arg)}|,
         line: 0,
         col: 0
       }}
    )
  end

  defp extract_sort_value(args) do
    case extract_single_value(args) do
      {:atom, a, _} when a in @sort_atoms -> a
      other -> sort_mode_error!(other)
    end
  end

  @spec sort_mode_error!(term()) :: no_return()
  defp sort_mode_error!(got) do
    throw(
      {:compile_error,
       %Error{
         message:
           "`.sort(by: ...)` takes :osm_id, :name, :distance or :qt, or an expression such as `t[\"key\"]`; got #{inspect(got)}",
         line: 0,
         col: 0
       }}
    )
  end

  # Directive arguments arrive as tag filters: `#limit(count: 5)`.
  defp extract_single_value([{:posarg, {:eq_num, _key, n}}]), do: {:number, n, %{}}
  defp extract_single_value([{:posarg, val}]), do: val
  defp extract_single_value([{:kwarg, _, val}]), do: val

  defp extract_single_value(_), do: nil

  # Variable / output refs compile to {:set_ref, name} — the executor resolves
  # the named set's geometry at run time ("name" for $name, "$$.name" for $$.name).
  defp extract_geometry_arg([{:kwarg, "geometry", geom}]),
    do: extract_geometry_arg([{:posarg, geom}])

  defp extract_geometry_arg(args) do
    case args do
      [{:posarg, {:var_ref, "$" <> _, _} = ref}] ->
        geometry_ref!(ref)

      [{:posarg, {:output_var_ref, _, _} = ref}] ->
        geometry_ref!(ref)

      [{:posarg, {:point, lat, lng, _}}] ->
        {:point, lng, lat}

      [{:posarg, {:bbox, _, _, _, _, _} = bbox}] ->
        geometry_ref!(bbox)

      [{:posarg, {:polygon, items, _}}] ->
        coords = Enum.map(items, fn {:point, lat, lng, _} -> {lng, lat} end)
        {:polygon, [GeometryRef.close_ring(coords)]}

      [{:posarg, {:linestring, items, _}}] ->
        {:linestring, Enum.map(items, &linestring_vertex!/1)}

      other ->
        throw(
          {:compile_error,
           %Error{message: "unsupported geometry argument: #{inspect(other)}", line: 0, col: 0}}
        )
    end
  end

  # `.bbox(south: s, west: w, north: n, east: e)`, in any order.
  defp bbox_from_keywords(kwargs) do
    # Directive arguments arrive as tag filters: `#bbox(south: 47.0, ...)`.
    values =
      Map.new(kwargs, fn
        {:kwarg, key, {:number, v, _}} -> {key, v}
        {:posarg, {:eq_num, key, v}} -> {key, v}
        other -> {other, nil}
      end)

    case values do
      %{"south" => s, "west" => w, "north" => n, "east" => e} -> {:bbox, s, w, n, e}
      _ -> argument_error!("south:, west:, north: and east: numbers", kwargs)
    end
  end

  # Every spatial method ANDs: the first becomes `spatial_filter`, later ones
  # (and directive filters the methods add to) go to `spatial_filters`.
  defp add_spatial(%Plan{spatial_filter: nil} = plan, filter), do: %{plan | spatial_filter: filter}

  defp add_spatial(%Plan{spatial_filters: filters} = plan, filter),
    do: %{plan | spatial_filters: filters ++ [filter]}

  defp around_filter(distance, {:point, lat, lng, _}), do: {:around, lat, lng, distance}
  defp around_filter(distance, {:var_ref, "$" <> name, _}), do: {:around_set, name, distance}

  defp around_filter(distance, {:output_var_ref, name, _}),
    do: {:around_set, "$$." <> name, distance}

  # Around a literal line or polygon: within `distance` of the shape.
  defp around_filter(distance, geom) when elem(geom, 0) in [:linestring, :polygon, :bbox],
    do: {:around_set_resolved, [literal_ewkt(geom)], distance}

  defp around_filter(_distance, geom), do: around_error!(geom)

  @spec around_error!(term()) :: no_return()
  defp around_error!(got) do
    throw(
      {:compile_error,
       %Error{
         message:
           "`.around()` takes a distance and a point, line, polygon or variable, got #{inspect(got)}",
         line: 0,
         col: 0
       }}
    )
  end

  defp literal_ewkt(geom) do
    case extract_geometry_arg([{:posarg, geom}]) do
      {:linestring, coords} ->
        "SRID=4326;LINESTRING(" <>
          Enum.map_join(coords, ",", fn {lng, lat} -> "#{lng} #{lat}" end) <> ")"

      {:polygon, rings} ->
        GeometryRef.polygon_ewkt(rings, 4326)
    end
  end

  defp linestring_vertex!({:point, lat, lng, _}) when is_number(lat) and is_number(lng),
    do: {lng, lat}

  defp linestring_vertex!(other) do
    throw(
      {:compile_error,
       %Error{
         message: "linestring() takes point(lat, lng) vertices, got #{inspect(other)}",
         line: 0,
         col: 0
       }}
    )
  end

  defp geometry_ref!(ast) do
    case GeometryRef.from_ast(ast) do
      {:ok, ref} ->
        ref

      :error ->
        throw(
          {:compile_error,
           %Error{message: "unsupported geometry argument: #{inspect(ast)}", line: 0, col: 0}}
        )
    end
  end

  defp compile_geometry_arg({:point, lat, lng, _pos}, _env)
       when is_number(lat) and is_number(lng) do
    {lat, lng}
  end

  defp compile_geometry_arg({:number, n, _pos}, _env), do: n

  defp compile_geometry_arg(expr, _env) do
    throw(
      {:compile_error,
       %Error{
         message:
           "positional route endpoints must be point(lat, lng), got #{inspect(expr)}; " <>
             "use origin: and destination: keywords",
         line: 0,
         col: 0
       }}
    )
  end

  # ── Computation compilation ───────────────────────────────────────

  defp compile_computation_params(:route, args, opts, env) do
    case args do
      [{:posarg, origin}, {:posarg, dest}] ->
        base = %{
          origin: compile_geometry_arg(origin, env),
          destination: compile_geometry_arg(dest, env)
        }

        Map.merge(base, compile_kwargs(opts))

      [] ->
        compile_kwargs(opts)

      _ ->
        positional_error!(:route, "an origin and a destination point", args)
    end
  end

  defp compile_computation_params(:isochrone, args, opts, _env) do
    base =
      case args do
        [{:posarg, {:point, lat, lng, _}} | _] -> %{center: {lat, lng}}
        [{:posarg, {:number, lat, _}}, {:posarg, {:number, lng, _}} | _] -> %{center: {lat, lng}}
        _ -> %{}
      end

    kwargs = compile_kwargs(opts)

    # Handle center: point(...) from kwargs
    kwargs =
      case kwargs do
        %{center: {:point, lat, lng, _}} -> %{kwargs | center: {lat, lng}}
        _ -> kwargs
      end

    Map.merge(base, kwargs)
  end

  # geocode("..."), autocomplete("...") and text_search("..."): the
  # positional string is the query text.
  @text_computations [:geocode, :autocomplete, :text_search]

  defp compile_computation_params(type, args, opts, _env) when type in @text_computations do
    base =
      case args do
        [{:posarg, {:string, query, _}} | _] -> %{query: query}
        _ -> %{}
      end

    Map.merge(base, compile_kwargs(opts))
  end

  # place_lookup("osm:node:1", "osm:way:2") or place_lookup(ids: [...]):
  # positional GIDs and `ids:` both land in `ids`.
  defp compile_computation_params(:place_lookup, args, opts, _env) do
    positional = for {:posarg, {:string, gid, _}} <- args, do: gid
    kwargs = compile_kwargs(opts)

    ids =
      case Map.get(kwargs, :ids) do
        nil -> positional
        gid when is_binary(gid) -> positional ++ [gid]
        gids when is_list(gids) -> positional ++ gids
      end

    Map.put(kwargs, :ids, ids)
  end

  @point_computations [:reverse_geocode, :nearest]

  defp compile_computation_params(type, args, opts, _env) when type in @point_computations do
    base =
      case args do
        [{:posarg, {:point, lat, lng, _}} | _] -> %{point: {lat, lng}}
        _ -> %{}
      end

    kwargs =
      opts
      |> compile_kwargs()
      |> normalize_point_kwarg(:point)

    Map.merge(base, kwargs)
  end

  defp compile_computation_params(:ev_route, args, opts, env) do
    base =
      case args do
        [{:posarg, origin}, {:posarg, dest}] ->
          %{
            origin: compile_geometry_arg(origin, env),
            destination: compile_geometry_arg(dest, env)
          }

        [] ->
          %{}

        _ ->
          positional_error!(:ev_route, "an origin and a destination point", args)
      end

    kwargs = compile_kwargs(opts)

    # Normalize point kwargs
    kwargs =
      kwargs
      |> normalize_point_kwarg(:origin)
      |> normalize_point_kwarg(:destination)

    # Map PlazaQL's `battery` to executor's `battery_capacity_wh`
    kwargs =
      case Map.pop(kwargs, :battery) do
        {nil, kw} -> kw
        {val, kw} -> Map.put(kw, :battery_capacity_wh, val)
      end

    Map.merge(base, kwargs)
  end

  # elevation(point(...)) and elevation(point(...), point(...)): positional
  # points are the points to look up, like `point:` / `points:`.
  defp compile_computation_params(:elevation, args, opts, _env) do
    kwargs = normalize_point_kwarg(compile_kwargs(opts), :point)

    case positional_points!(:elevation, args) do
      [] -> kwargs
      [point] -> Map.put(kwargs, :point, point)
      points -> Map.put(kwargs, :points, points)
    end
  end

  # elevation_profile(linestring(...)): the line's vertices are the profile points.
  defp compile_computation_params(:elevation_profile, args, opts, _env) do
    kwargs = compile_kwargs(opts)

    case args do
      [] ->
        kwargs

      [{:posarg, {:linestring, items, _}}] ->
        Map.put(kwargs, :points, Enum.map(items, &point_tuple!(:elevation_profile, &1)))

      [{:posarg, other}] ->
        positional_error!(:elevation_profile, "a linestring(...)", other)

      [_, _ | _] ->
        positional_error!(:elevation_profile, "one linestring(...)", args)
    end
  end

  # map_match(linestring(...)): the line's vertices are the GPS trace.
  defp compile_computation_params(:map_match, args, opts, _env) do
    kwargs = compile_kwargs(opts)

    case args do
      [] ->
        kwargs

      [{:posarg, {:linestring, items, _}}] ->
        Map.put(kwargs, :points, Enum.map(items, &point_tuple!(:map_match, &1)))

      [{:posarg, other} | _] ->
        positional_error!(:map_match, "one linestring(...) trace", other)
    end
  end

  # matrix([origins...], [destinations...]): the two point lists.
  defp compile_computation_params(:matrix, args, opts, _env) do
    kwargs = compile_kwargs(opts)

    case args do
      [] ->
        kwargs

      [{:posarg, {:list, _, _} = origins}, {:posarg, {:list, _, _} = destinations}] ->
        Map.merge(kwargs, %{origins: origins, destinations: destinations})

      _ ->
        positional_error!(:matrix, "two point lists, origins then destinations", args)
    end
  end

  # optimize(p1, p2, p3, ...): positional points are the waypoints.
  defp compile_computation_params(:optimize, args, opts, _env) do
    kwargs = compile_kwargs(opts)

    case positional_points!(:optimize, args) do
      [] -> kwargs
      points -> Map.put(kwargs, :waypoints, points)
    end
  end

  defp compile_computation_params(type, args, opts, _env) do
    case args do
      [] -> compile_kwargs(opts)
      [{:posarg, first} | _] -> positional_error!(type, "keyword arguments", first)
    end
  end

  defp positional_points!(type, args) do
    Enum.map(args, fn {:posarg, value} -> point_tuple!(type, value) end)
  end

  defp point_tuple!(_type, {:point, lat, lng, _}) when is_number(lat) and is_number(lng),
    do: {lat, lng}

  defp point_tuple!(type, other), do: positional_error!(type, "point(lat, lng) values", other)

  @spec positional_error!(atom(), String.t(), term()) :: no_return()
  defp positional_error!(type, expected, got) do
    throw(
      {:compile_error,
       %Error{
         message: "`#{type}()` takes #{expected}, got #{inspect(got)}",
         line: 0,
         col: 0
       }}
    )
  end

  # Keywords whose `[...]` value compiles to a plain list of strings.
  @string_list_kwargs [
    "include",
    "exclude",
    "expansion_properties",
    "layers",
    "ids",
    "addresses",
    "datasets",
    "avoid_datasets",
    "waypoint_names"
  ]

  defp compile_kwargs(opts) do
    Map.new(opts, fn
      {:kwarg, key, {:list, items, _}} when key in @string_list_kwargs ->
        {kwarg_name!(key), Enum.map(items, &string_item!(key, &1))}

      {:kwarg, key, {:number, n, _}} ->
        {kwarg_name!(key), n}

      {:kwarg, key, {:string, s, _}} ->
        {kwarg_name!(key), s}

      {:kwarg, key, {:bool, b, _}} ->
        {kwarg_name!(key), b}

      {:kwarg, key, {:atom, a, _}} ->
        {kwarg_name!(key), a}

      {:kwarg, key, value} ->
        {kwarg_name!(key), value}

      other ->
        other
    end)
  end

  # Keyword names computations accept beyond @known_atoms (which also lists
  # atom *values*). Kept separate so adding a computation option never makes a
  # new atom value legal.
  @computation_kwarg_names Map.new(
                             ~w(action address alternatives avoid_datasets axle_count axle_load battery
                                battery_capacity_wh boundary_gid connector_types country
                                country_code county dataset_name_field datasets depart_at destinations exclude
                                expansion_properties focus hazmat height ids include
                                initial_charge_pct layers length locality locations metric
                                min_charge_pct min_power_kw neighbourhood origins points
                                postalcode region traffic_model waypoints weight width steps
                                roundtrip overview geometries annotations denoise generalize
                                fallback_speed radiuses lang layer addresses units verbal
                                voice_instructions banner_instructions roundabout_exits voice_units
                                waypoint_names use_bus use_rail use_transfers max_walk_m
                                max_transfers)a,
                             &{Atom.to_string(&1), &1}
                           )

  defp kwarg_name!(name) do
    case Map.fetch(@computation_kwarg_names, name) do
      {:ok, atom} -> atom
      :error -> safe_to_atom!(name)
    end
  end

  defp string_item!(_key, {:string, s, _}), do: s

  defp string_item!(key, other) do
    throw(
      {:compile_error,
       %Error{
         message: "`#{key}:` list items must be strings, got #{inspect(other)}",
         line: 0,
         col: 0
       }}
    )
  end

  defp normalize_point_kwarg(kwargs, key) do
    case kwargs do
      %{^key => {:point, lat, lng, _}} -> %{kwargs | key => {lat, lng}}
      _ -> kwargs
    end
  end

  # ── Dataset Validation ──────────────────────────────────────────────

  defp validate_dataset_slugs(slugs) when length(slugs) > @max_datasets do
    throw(
      {:compile_error,
       %Error{
         message: "too many datasets (max #{@max_datasets}, got #{length(slugs)})",
         line: 0,
         col: 0
       }}
    )
  end

  defp validate_dataset_slugs(slugs) do
    # Return raw slugs — caller resolves them before SQL generation.
    # Tag each as {:uuid, id} or {:slug, name} so the caller knows what to resolve.
    Enum.map(slugs, fn slug ->
      if Regex.match?(@uuid_re, slug) do
        {:uuid, slug}
      else
        {:slug, slug}
      end
    end)
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp ensure_output_options(%{output_options: nil}), do: %OutputOptions{}
  defp ensure_output_options(%{output_options: opts}), do: opts

  defp safe_to_atom!(name) when is_binary(name) do
    case Map.fetch(@known_atoms, name) do
      {:ok, atom} ->
        atom

      :error ->
        throw(
          {:compile_error, %Error{message: "unknown atom value: #{inspect(name)}", line: 0, col: 0}}
        )
    end
  end
end
