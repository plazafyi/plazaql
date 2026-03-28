defmodule PlazaQL.Compiler do
  @moduledoc """
  Compiles PlazaQL AST into `PlazaQL.Plan` structs.

  Transforms parsed (and optionally type-checked) AST nodes into the unified
  Plan IR that a query executor can run.
  """

  alias PlazaQL.Error
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

    result = Enum.reduce(ast, env, &process_top_level/2)

    plans = Enum.reverse(result.plans)

    steps = Enum.reverse(result.steps)
    output_names = Enum.reverse(result.output_names)

    {:ok, %{plans: plans, steps: steps, output_names: output_names}}
  catch
    {:compile_error, %Error{} = error} -> {:error, [error]}
  end

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

  defp process_top_level({:directive, method_name, args, _pos}, env) do
    %{env | directives: env.directives ++ [{method_name, args}]}
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

  defp compile_expr({:computation, comp_type, args, opts, _pos}, env) do
    params = compile_computation_params(comp_type, args, opts, env)
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

  defp compile_expr(expr, _env) do
    throw(
      {:compile_error,
       %Error{message: "unknown expression node: #{inspect(expr)}", line: 0, col: 0}}
    )
  end

  defp find_within_geometry(directives) do
    Enum.find_value(directives, fn
      {:within, [{:posarg, geom}]} -> geom
      _ -> nil
    end)
  end

  # ── Method application ────────────────────────────────────────────

  defp apply_methods(plan, methods, env) do
    Enum.reduce(methods, plan, &apply_method(&2, &1, env))
  end

  defp apply_directives(plan, [], _env), do: plan

  defp apply_directives(plan, directives, env) do
    Enum.reduce(directives, plan, fn {method_name, args}, acc ->
      apply_method(acc, {:method, method_name, args, %{}}, env)
    end)
  end

  # -- Spatial methods --

  defp apply_method(plan, {:method, :around, args, _pos}, _env) do
    case args do
      [{:posarg, {:number, distance, _}}, {:posarg, {:point, lat, lng, _}}] ->
        %{plan | spatial_filter: {:around, lat, lng, distance}}

      [{:posarg, {:number, distance, _}}, {:posarg, {:var_ref, "$" <> name, _}}] ->
        %{plan | spatial_filter: {:around_set, name, distance}}

      [{:posarg, {:number, distance, _}}, {:posarg, {:output_var_ref, name, _}}] ->
        %{plan | spatial_filter: {:around_set, "$$." <> name, distance}}

      [{:kwarg, "distance", {:number, distance, _}}, {:kwarg, "geometry", {:point, lat, lng, _}}] ->
        %{plan | spatial_filter: {:around, lat, lng, distance}}

      [
        {:kwarg, "distance", {:number, distance, _}},
        {:kwarg, "geometry", {:output_var_ref, name, _}}
      ] ->
        %{plan | spatial_filter: {:around_set, "$$." <> name, distance}}

      _ ->
        plan
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
        %{plan | spatial_filter: {:bbox, s, w, n, e}}

      _ ->
        plan
    end
  end

  defp apply_method(plan, {:method, :h3, args, _pos}, _env) do
    case args do
      [{:posarg, {:string, cell, _}}] -> %{plan | spatial_filter: {:h3, cell}}
      _ -> plan
    end
  end

  # Predicate spatial methods
  @predicate_methods ~w(within intersects contains crosses touches not_within not_intersects not_contains)a

  defp apply_method(plan, {:method, method_name, args, _pos}, _env)
       when method_name in @predicate_methods do
    geometry = extract_geometry_arg(args)

    %{plan | spatial_filter: {:predicate, method_name, geometry}}
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
    items = extract_atom_list(args)
    opts = ensure_output_options(plan)
    %{plan | output_options: %{opts | include: MapSet.new(items)}}
  end

  defp apply_method(plan, {:method, :sort, args, _pos}, _env) do
    value = extract_sort_value(args)
    opts = ensure_output_options(plan)
    %{plan | output_options: %{opts | sort: value}}
  end

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

  # -- Output mode methods --

  defp apply_method(plan, {:method, :count, _args, _pos}, _env), do: %{plan | output_mode: :count}
  defp apply_method(plan, {:method, :ids, _args, _pos}, _env), do: %{plan | output_mode: :ids}
  defp apply_method(plan, {:method, :tags, _args, _pos}, _env), do: %{plan | output_mode: :tags}
  defp apply_method(plan, {:method, :skel, _args, _pos}, _env), do: %{plan | output_mode: :skel}
  defp apply_method(plan, {:method, :geom, _args, _pos}, _env), do: %{plan | output_mode: :full}

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

  # -- Recurse --

  defp apply_method(plan, {:method, :expand, args, _pos}, _env) do
    direction =
      case args do
        [{:posarg, {:atom, dir, _}}] when dir in [:down, :up, :down_full, :up_full] -> dir
        _ -> :down
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
      _ -> 0
    end
  end

  defp extract_string_list(args) do
    Enum.flat_map(args, fn
      {:posarg, {:string, s, _}} -> [s]
      {:posarg, {:identifier, s, _}} -> [s]
      {:kwarg, _, {:string, s, _}} -> [s]
      _ -> []
    end)
  end

  defp extract_atom_list(args) do
    Enum.flat_map(args, fn
      {:posarg, {:atom, a, _}} -> [a]
      {:posarg, {:identifier, s, _}} -> [safe_to_atom!(s)]
      {:posarg, {:string, s, _}} -> [safe_to_atom!(s)]
      _ -> []
    end)
  end

  defp extract_sort_value(args) do
    case extract_single_value(args) do
      {:atom, a, _} -> a
      {:identifier, s, _} -> safe_to_atom!(s)
      {:string, s, _} -> safe_to_atom!(s)
      _ -> nil
    end
  end

  defp extract_single_value([{:posarg, val}]), do: val
  defp extract_single_value([{:kwarg, _, val}]), do: val
  defp extract_single_value(_), do: nil

  defp extract_geometry_arg(args) do
    case args do
      [{:posarg, {:var_ref, "$" <> _name, _pos}}] ->
        # Placeholder — executor resolves variable geometry at runtime
        {:point, 0.0, 0.0}

      [{:posarg, {:output_var_ref, _name, _pos}}] ->
        # Placeholder — executor resolves output variable geometry at runtime
        {:point, 0.0, 0.0}

      [{:posarg, {:point, lat, lng, _}}] ->
        {:point, lng, lat}

      [{:posarg, {:polygon, items, _}}] ->
        coords = Enum.map(items, fn {:point, lat, lng, _} -> {lng, lat} end)

        coords =
          if List.first(coords) != List.last(coords), do: coords ++ [hd(coords)], else: coords

        {:polygon, [coords]}

      _ ->
        {:point, 0.0, 0.0}
    end
  end

  defp compile_geometry_arg({:point, lat, lng, _pos}, _env)
       when is_number(lat) and is_number(lng) do
    {lat, lng}
  end

  defp compile_geometry_arg({:number, n, _pos}, _env), do: n
  defp compile_geometry_arg(_expr, _env), do: {0.0, 0.0}

  # ── Computation compilation ───────────────────────────────────────

  defp compile_computation_params(:route, args, opts, env) do
    case args do
      [{:posarg, origin}, {:posarg, dest} | _] ->
        base = %{
          origin: compile_geometry_arg(origin, env),
          destination: compile_geometry_arg(dest, env)
        }

        Map.merge(base, compile_kwargs(opts))

      _ ->
        compile_kwargs(opts)
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

  defp compile_computation_params(:geocode, args, opts, _env) do
    base =
      case args do
        [{:posarg, {:string, query, _}} | _] -> %{query: query}
        _ -> %{}
      end

    Map.merge(base, compile_kwargs(opts))
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
        [{:posarg, origin}, {:posarg, dest} | _] ->
          %{
            origin: compile_geometry_arg(origin, env),
            destination: compile_geometry_arg(dest, env)
          }

        _ ->
          %{}
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

  defp compile_computation_params(_type, _args, opts, _env) do
    compile_kwargs(opts)
  end

  defp compile_kwargs(opts) do
    Map.new(opts, fn
      {:kwarg, key, {:number, n, _}} -> {safe_to_atom!(key), n}
      {:kwarg, key, {:string, s, _}} -> {safe_to_atom!(key), s}
      {:kwarg, key, {:bool, b, _}} -> {safe_to_atom!(key), b}
      {:kwarg, key, {:atom, a, _}} -> {safe_to_atom!(key), a}
      {:kwarg, key, value} -> {safe_to_atom!(key), value}
      other -> other
    end)
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
