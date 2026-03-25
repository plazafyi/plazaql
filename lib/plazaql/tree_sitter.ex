defmodule PlazaQL.TreeSitter do
  @moduledoc """
  Tree-sitter based parser for PlazaQL.

  Uses the tree-sitter CLI to parse PQL source into a CST (XML),
  then transforms it into the same AST format as the NimbleParsec parser.

  The AST format is documented in `PlazaQL.Parser`.
  """

  alias PlazaQL.Error

  # xmerl record accessors (require before module attributes)
  require Record

  @grammar_path Path.expand("../../..", __DIR__)
  @lib_path Path.join([
              System.get_env("HOME", "/tmp"),
              ".cache",
              "tree-sitter",
              "lib",
              "plazaql.dylib"
            ])

  # Safe atom allowlists (same as in the NimbleParsec parser)
  @method_atoms Map.new(
                  ~w(area around avg bbox buffer centroid contains count crosses distance
                     elevation expand fields filter filter_expr first geom group_by h3
                     has_member ids include index intersects last length limit max min
                     member_of not_contains not_intersects not_within offset precision
                     simplify skel sort sort_expr sum tags touches within)a,
                  &{Atom.to_string(&1), &1}
                )

  @literal_atoms Map.new(
                   ~w(asc auto bicycle car csv desc distance down down_full
                      foot geojson json node nwr qt relation truck up up_full
                      way xml)a,
                   &{Atom.to_string(&1), &1}
                 )

  @element_type_atoms %{
    "node" => :node,
    "way" => :way,
    "relation" => :relation,
    "nwr" => :nwr
  }

  Record.defrecordp(:xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl"))
  Record.defrecordp(:xmlText, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl"))

  Record.defrecordp(
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  @doc """
  Parse PQL source using tree-sitter and return the same AST as NimbleParsec parser.

  Returns `{:ok, [ast_node]}` or `{:error, [%PlazaQL.Error{}]}`.
  """
  @spec parse(String.t()) :: {:ok, [term()]} | {:error, [Error.t()]}
  def parse(source) do
    with {:ok, xml} <- run_tree_sitter(source),
         {:ok, cst} <- parse_xml(xml) do
      transform_program(cst, source)
    end
  end

  # ── Tree-sitter CLI invocation ──────────────────────────────────

  defp run_tree_sitter(source) do
    tmp_path =
      System.tmp_dir!()
      |> Path.join("plazaql_#{:erlang.phash2(self())}_#{System.unique_integer([:positive])}.pql")

    try do
      File.write!(tmp_path, source)

      # Use --lib-path with cached dylib if available, otherwise fall back to -p
      {args, opts} =
        if File.exists?(@lib_path) do
          {["parse", "-x", "--lib-path", @lib_path, "--lang-name", "plazaql", tmp_path],
           [stderr_to_stdout: false]}
        else
          {["parse", "-x", "-p", @grammar_path, tmp_path],
           [cd: @grammar_path, stderr_to_stdout: false]}
        end

      # Capture both stdout and stderr
      {output, exit_code} =
        System.cmd("tree-sitter", args, Keyword.put(opts, :stderr_to_stdout, true))

      # Split: XML goes to stdout (before error lines), errors to stderr
      # tree-sitter mixes XML and error info when stderr_to_stdout is true
      # The XML always starts with <?xml, error lines come after
      {xml, stderr_lines} = split_xml_and_errors(output)

      cond do
        exit_code == 0 ->
          {:ok, xml}

        String.contains?(xml, "<?xml") ->
          # Parse succeeded with warnings/MISSING nodes
          # Check stderr for MISSING indicators
          missing_errors = extract_missing_errors(stderr_lines, source)

          if missing_errors != [] do
            {:error, missing_errors}
          else
            {:ok, xml}
          end

        true ->
          {:error,
           [%Error{line: 1, col: 1, message: "tree-sitter parse failed: #{String.trim(output)}"}]}
      end
    after
      File.rm(tmp_path)
    end
  end

  # ── XML parsing ─────────────────────────────────────────────────

  defp parse_xml(xml) do
    # tree-sitter XML output may contain raw UTF-8 text from source;
    # add encoding declaration and sanitize for xmerl
    sanitized =
      xml
      |> String.replace(~r/^<\?xml version="1\.0"\?>/, ~s(<?xml version="1.0" encoding="UTF-8"?>))
      |> sanitize_xml_text()

    charlist = String.to_charlist(sanitized)
    {doc, _} = :xmerl_scan.string(charlist, quiet: true)
    {:ok, doc}
  rescue
    e -> {:error, [%Error{line: 1, col: 1, message: "XML parse error: #{inspect(e)}"}]}
  catch
    :exit, reason ->
      {:error, [%Error{line: 1, col: 1, message: "XML parse error: #{inspect(reason)}"}]}
  end

  # Sanitize XML text content by escaping characters that xmerl can't handle.
  # xmerl_scan uses latin1 internally, so we need to escape non-ASCII codepoints.
  defp sanitize_xml_text(xml) do
    xml
    |> String.graphemes()
    |> Enum.map_join(fn grapheme ->
      <<first_byte, _rest::binary>> = grapheme

      if first_byte > 127 do
        # Escape non-ASCII as numeric character references
        # credo:disable-for-lines:3 Credo.Check.Refactor.Nesting
        grapheme
        |> String.to_charlist()
        |> Enum.map_join(fn cp -> "&##{cp};" end)
      else
        grapheme
      end
    end)
  end

  # ── CST → AST transformation ───────────────────────────────────

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp transform_program(doc, source) do
    # Navigate: sources > source > program
    program_el = find_child(find_child(doc, :source), :program)

    if program_el == nil do
      {:error, [%Error{line: 1, col: 1, message: "no program node in parse tree"}]}
    else
      # Check for ERROR nodes — return at most one error (outermost)
      errors =
        collect_errors(program_el, source)
        |> Enum.uniq_by(fn e -> {e.line, e.col} end)
        |> Enum.take(1)

      if errors != [] do
        {:error, errors}
      else
        statements =
          named_children(program_el)
          |> Enum.flat_map(fn child ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case elem_name(child) do
              :bare_statement -> [transform_bare_statement(child)]
              :variable_assignment -> [transform_variable_assignment(child)]
              :output_assignment -> [transform_output_assignment(child)]
              :directive -> [transform_directive(child)]
              # Skip comments
              :line_comment -> []
              :block_comment -> []
              _ -> []
            end
          end)

        {:ok, statements}
      end
    end
  end

  # ── Statement transformations ───────────────────────────────────

  defp transform_bare_statement(el) do
    child = first_named_child(el)
    pos = make_pos(el)
    expr = transform_expression(child)
    {:bare_output, expr, pos}
  end

  defp transform_variable_assignment(el) do
    name_el = field_child(el, "name")
    value_el = field_child(el, "value")
    pos = make_pos(el)
    var_name = text_content(name_el)
    expr = transform_expression(value_el)
    {:var_assign, var_name, expr, pos}
  end

  defp transform_output_assignment(el) do
    target_el = field_child(el, "target")
    value_el = field_child(el, "value")
    pos = make_pos(el)

    name =
      case elem_name(target_el) do
        :output_ref ->
          nil

        :output_named_ref ->
          text = text_content(target_el)
          # $$.name -> extract "name"
          String.replace_prefix(text, "$$.", "")
      end

    expr = transform_expression(value_el)
    {:output, name, expr, pos}
  end

  defp transform_directive(el) do
    name_el = field_child(el, "name")
    pos = make_pos(el)
    dir_name = text_content(name_el)

    # Check what kind of args the directive has
    children = named_children(el)
    # Skip the identifier (name field)
    arg_children =
      Enum.reject(children, fn c ->
        get_field(c) == "name"
      end)

    case dir_name do
      "filter" ->
        # Could be tag filter list or expression filter
        case arg_children do
          [tag_list] ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case elem_name(tag_list) do
              :tag_filter_list ->
                filters = transform_tag_filter_list(tag_list)
                {:directive, :filter, filters, pos}

              :filter_expression ->
                expr = transform_filter_expression(tag_list)
                {:directive, :filter_expr, expr, pos}

              _ ->
                filters = transform_tag_filter_list(tag_list)
                {:directive, :filter, filters, pos}
            end

          _ ->
            {:directive, :filter, [], pos}
        end

      _ ->
        args = transform_directive_args(arg_children)
        {:directive, to_method_atom(dir_name), args, pos}
    end
  end

  defp transform_directive_args(children) do
    children
    |> Enum.flat_map(fn child ->
      case elem_name(child) do
        :tag_filter_list ->
          transform_tag_filter_list(child)

        :filter_expression ->
          [transform_filter_expression(child)]

        _ ->
          [transform_to_arg(child)]
      end
    end)
  end

  # ── Expression transformations ──────────────────────────────────

  # credo:disable-for-lines:150 Credo.Check.Refactor.CyclomaticComplexity
  # credo:disable-for-lines:150 Credo.Check.Refactor.ABCSize
  defp transform_expression(el) do
    case elem_name(el) do
      :search_expression ->
        transform_search(el)

      :boundary_expression ->
        transform_boundary(el)

      :method_call ->
        transform_method_call(el)

      :union_expression ->
        transform_set_op(el, :union)

      :intersection_expression ->
        transform_set_op(el, :intersection)

      :difference_expression ->
        transform_set_op(el, :difference)

      :computation ->
        transform_computation(el)

      :variable_ref ->
        transform_var_ref(el)

      :output_ref ->
        transform_var_ref(el)

      :output_named_ref ->
        transform_output_var_ref(el)

      :bracket_ref ->
        transform_bracket_ref(el)

      :output_bracket_ref ->
        transform_output_bracket_ref(el)

      :point_constructor ->
        transform_point(el)

      :linestring_constructor ->
        transform_geometry(el, :linestring)

      :polygon_constructor ->
        transform_geometry(el, :polygon)

      :circle_constructor ->
        transform_geometry(el, :circle)

      :bbox_constructor ->
        transform_bbox(el)

      :list_literal ->
        transform_list(el)

      :parenthesized_expression ->
        transform_paren(el)

      :number ->
        transform_number(el)

      :string ->
        transform_string(el)

      :boolean ->
        transform_boolean(el)

      :atom ->
        transform_atom(el)

      :bare_identifier ->
        transform_bare_identifier(el)

      :identifier ->
        transform_identifier_as_bare(el)

      # Filter expressions that can appear as method arguments
      :filter_expression ->
        transform_filter_expression(el)

      :filter_and_expression ->
        transform_filter_binop(el)

      :filter_or_expression ->
        transform_filter_binop(el)

      :filter_eq_expression ->
        transform_filter_binop(el)

      :filter_cmp_expression ->
        transform_filter_binop(el)

      :filter_add_expression ->
        transform_filter_binop(el)

      :filter_mul_expression ->
        transform_filter_binop(el)

      :filter_unary_expression ->
        transform_filter_unary(el)

      :filter_paren_expression ->
        transform_filter_paren(el)

      :filter_function_call ->
        transform_filter_function_call(el)

      :tag_access ->
        transform_tag_access(el)

      :prop_accessor ->
        transform_prop_accessor(el)

      :geom_function ->
        transform_geom_function(el)

      :coerce_function ->
        transform_coerce_function(el)

      :string_function ->
        transform_string_function(el)

      :distance_function ->
        transform_distance_function(el)

      :size_function ->
        transform_size_function(el)

      :dataset_source ->
        transform_dataset_source(el)

      :keyword_argument ->
        transform_kwarg(el)

      other ->
        raise "Unknown CST node type: #{inspect(other)} at #{inspect(make_pos(el))}"
    end
  end

  # ── Search ──────────────────────────────────────────────────────

  defp transform_search(el) do
    pos = make_pos(el)
    type_el = field_child(el, "type")
    children = named_children(el)

    # Find tag_filter_list and dataset_source
    tag_list_el = Enum.find(children, fn c -> elem_name(c) == :tag_filter_list end)
    dataset_el = Enum.find(children, fn c -> elem_name(c) == :dataset_source end)

    type =
      cond do
        dataset_el != nil ->
          slugs = transform_dataset_slugs(dataset_el)
          {:dataset, slugs}

        type_el != nil ->
          text = text_content(type_el) |> String.trim()
          Map.fetch!(@element_type_atoms, text)

        true ->
          nil
      end

    filters =
      if tag_list_el do
        transform_tag_filter_list(tag_list_el)
      else
        []
      end

    {:search, type, filters, [], pos}
  end

  defp transform_dataset_slugs(el) do
    named_children(el)
    |> Enum.filter(fn c -> elem_name(c) == :string end)
    |> Enum.map(fn c -> extract_string_text(c) end)
  end

  # ── Boundary ────────────────────────────────────────────────────

  defp transform_boundary(el) do
    pos = make_pos(el)
    children = named_children(el)
    tag_list_el = Enum.find(children, fn c -> elem_name(c) == :tag_filter_list end)

    filters =
      if tag_list_el do
        transform_tag_filter_list(tag_list_el)
      else
        []
      end

    {:boundary, filters, pos}
  end

  # ── Method call (chain) ─────────────────────────────────────────

  defp transform_method_call(el) do
    receiver_el = field_child(el, "receiver")
    method_el = field_child(el, "method")

    receiver = transform_expression(receiver_el)
    method = transform_method(method_el)

    # Special handling: if receiver is a search, attach methods directly
    attach_method(receiver, method)
  end

  defp attach_method({:search, type, filters, existing_methods, pos}, method) do
    {:search, type, filters, existing_methods ++ [method], pos}
  end

  defp attach_method(receiver, method) do
    {:chain, receiver, method}
  end

  defp transform_method(el) do
    pos = make_pos(el)
    name_el = field_child(el, "name")
    method_name = text_content(name_el)
    children = named_children(el)

    # Get argument children (everything except the name identifier)
    arg_children =
      Enum.reject(children, fn c -> get_field(c) == "name" end)

    case method_name do
      "filter" ->
        transform_filter_method(arg_children, pos)

      "sort" ->
        transform_sort_method(arg_children, pos)

      name when name in ["group_by", "sum", "min", "max", "avg"] ->
        transform_expr_arg_method(name, arg_children, pos)

      _ ->
        transform_general_method(method_name, arg_children, pos)
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp transform_filter_method(arg_children, pos) do
    # Classify the children
    has_tag_filters =
      Enum.any?(arg_children, fn c ->
        elem_name(c) in [:tag_filter_list, :tag_filter, :regex_key_filter]
      end)

    has_filter_exprs =
      Enum.any?(arg_children, fn c ->
        elem_name(c) in [
          :filter_expression,
          :filter_and_expression,
          :filter_or_expression,
          :filter_eq_expression,
          :filter_cmp_expression,
          :filter_function_call,
          :tag_access
        ]
      end)

    if has_filter_exprs and not has_tag_filters do
      # Expression filter: .filter(t["key"] > 5)
      case arg_children do
        [child] ->
          expr = transform_expression(child)
          {:method, :filter_expr, expr, pos}

        _ ->
          expr = transform_expression(hd(arg_children))
          {:method, :filter_expr, expr, pos}
      end
    else
      # Tag filter: .filter(cuisine: "italian")
      filters =
        Enum.flat_map(arg_children, fn c ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case elem_name(c) do
            :tag_filter_list -> transform_tag_filter_list(c)
            :tag_filter -> [transform_tag_filter(c)]
            :regex_key_filter -> [transform_regex_key_filter(c)]
            _ -> []
          end
        end)

      {:method, :filter, filters, pos}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp transform_sort_method(arg_children, pos) do
    # Determine if this is a sort_expr (filter expression arg) or general sort (keyword-only)
    # sort_expr: .sort(t["name"]) or .sort(by: t["name"]) or .sort(distance(...))
    # general sort: .sort(by: :qt) or .sort(by: distance)

    kwargs =
      arg_children
      |> Enum.filter(fn c -> elem_name(c) == :keyword_argument end)
      |> Enum.map(fn c ->
        key = text_content(field_child(c, "key"))
        value = field_child(c, "value")
        {key, value}
      end)
      |> Map.new()

    # Positional filter expressions (not keyword args)
    pos_exprs =
      Enum.filter(arg_children, fn c ->
        elem_name(c) not in [:keyword_argument] and get_field(c) == nil
      end)

    by_el = Map.get(kwargs, "by")
    order_el = Map.get(kwargs, "order")

    # Check if we have a filter expression argument (tag_access, distance, etc.)
    has_filter_expr =
      cond do
        pos_exprs != [] -> has_filter_expression_content?(hd(pos_exprs))
        by_el != nil -> has_filter_expression_content?(by_el)
        true -> false
      end

    if has_filter_expr do
      # sort_expr form
      expr =
        cond do
          by_el != nil -> transform_expression(by_el)
          pos_exprs != [] -> transform_expression(hd(pos_exprs))
          true -> nil
        end

      order =
        if order_el do
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case transform_expression(order_el) do
            {:atom, atom_val, _} -> atom_val
            _ -> :asc
          end
        else
          :asc
        end

      {:method, :sort_expr, expr, order, pos}
    else
      # General sort method — produce standard method args
      args = transform_method_args(arg_children)
      {:method, :sort, args, pos}
    end
  end

  @filter_expression_types [
    :filter_expression,
    :tag_access,
    :prop_accessor,
    :geom_function,
    :distance_function,
    :coerce_function,
    :string_function,
    :size_function,
    :filter_function_call,
    :filter_and_expression,
    :filter_or_expression,
    :filter_eq_expression,
    :filter_cmp_expression,
    :filter_add_expression,
    :filter_mul_expression,
    :filter_unary_expression,
    :filter_paren_expression
  ]

  defp has_filter_expression_content?(el) do
    case elem_name(el) do
      name when name in @filter_expression_types ->
        true

      _ ->
        # Check children recursively
        named_children(el) |> Enum.any?(&has_filter_expression_content?/1)
    end
  end

  defp transform_expr_arg_method(name, arg_children, pos) do
    # These methods take a filter expression as argument
    expr =
      case arg_children do
        [child] -> transform_expression(child)
        _ -> nil
      end

    method_atom =
      case name do
        "group_by" -> :group_by
        "sum" -> :sum
        "min" -> :min
        "max" -> :max
        "avg" -> :avg
      end

    {:method, method_atom, expr, pos}
  end

  defp transform_general_method(name, arg_children, pos) do
    method_atom = to_method_atom(name)

    if arg_children == [] do
      {:method, method_atom, [], pos}
    else
      args = transform_method_args(arg_children)
      {:method, method_atom, args, pos}
    end
  end

  defp transform_method_args(children) do
    children
    |> Enum.flat_map(fn child ->
      result = transform_to_arg(child)

      case result do
        {:__tag_filters__, filters} ->
          # Expand tag filters into individual kwargs when in method context
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          Enum.map(filters, fn
            {:eq, key, val} -> {:kwarg, key, {:string, val, %{line: 1, col: 1}}}
            {:exists, key} -> {:kwarg, key, {:atom, :exists, %{line: 1, col: 1}}}
            filter -> {:posarg, filter}
          end)

        other ->
          [other]
      end
    end)
    |> clean_args()
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp transform_to_arg(el) do
    case elem_name(el) do
      :keyword_argument ->
        key = text_content(field_child(el, "key"))
        value = transform_expression(field_child(el, "value"))
        {:kwarg, key, value}

      :tag_filter ->
        # tag_filter in method args context acts as keyword argument (key: value)
        key = text_content(field_child(el, "key"))
        value_el = field_child(el, "value")

        value =
          case elem_name(value_el) do
            :string -> transform_string(value_el)
            :number -> transform_number(value_el)
            :tag_exists -> {:atom, :exists, make_pos(value_el)}
            _ -> transform_expression(value_el)
          end

        {:kwarg, key, value}

      :tag_filter_list ->
        # When a tag_filter_list appears in method args, treat each filter as a kwarg
        # Actually return the filters directly for filter methods
        tag_filters = transform_tag_filter_list(el)
        {:__tag_filters__, tag_filters}

      :filter_expression ->
        # Unwrap filter_expression to get the inner value
        inner = first_named_child(el)

        if inner != nil do
          {:posarg, transform_expression(inner)}
        else
          {:posarg, nil}
        end

      _ ->
        {:posarg, transform_expression(el)}
    end
  end

  defp clean_args(args) do
    Enum.reject(args, &match?({:__empty_args__}, &1))
  end

  # ── Computation ─────────────────────────────────────────────────

  defp transform_computation(el) do
    pos = make_pos(el)
    name_el = field_child(el, "name")
    comp_name = text_content(name_el) |> String.trim()

    # Safe: constrained to known computation names
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    comp_atom = String.to_atom(comp_name)

    # arguments is a repeated field — collect all children with field="arguments"
    arg_els = field_children(el, "arguments")

    if arg_els != [] do
      args =
        arg_els
        |> Enum.map(&transform_to_arg/1)
        |> clean_args()

      {posargs, kwargs} = split_args_opts(args)
      {:computation, comp_atom, posargs, kwargs, pos}
    else
      {:computation, comp_atom, [], [], pos}
    end
  end

  # ── Set operations ──────────────────────────────────────────────

  defp transform_set_op(el, op) do
    left_el = field_child(el, "left")
    right_el = field_child(el, "right")
    left = transform_expression(left_el)
    right = transform_expression(right_el)
    pos = extract_node_pos(left)
    {op, left, right, pos}
  end

  # ── Variable references ─────────────────────────────────────────

  defp transform_var_ref(el) do
    pos = make_pos(el)
    name = text_content(el)
    {:var_ref, name, pos}
  end

  defp transform_output_var_ref(el) do
    pos = make_pos(el)
    text = text_content(el)
    # $$.name -> extract "name"
    name = String.replace_prefix(text, "$$.", "")
    {:output_var_ref, name, pos}
  end

  defp transform_bracket_ref(el) do
    pos = make_pos(el)
    var_el = field_child(el, "variable")
    attr_el = field_child(el, "attribute")
    var_name = text_content(var_el)
    attr = extract_bracket_attr(attr_el)
    {:bracket_ref, var_name, attr, pos}
  end

  defp transform_output_bracket_ref(el) do
    pos = make_pos(el)
    var_el = field_child(el, "variable")
    attr_el = field_child(el, "attribute")
    var_name = text_content(var_el)
    attr = extract_bracket_attr(attr_el)
    {:bracket_ref, var_name, attr, pos}
  end

  defp extract_bracket_attr(el) do
    case elem_name(el) do
      :string -> extract_string_text(el)
      :identifier -> text_content(el)
      _ -> text_content(el)
    end
  end

  # ── Geometry constructors ───────────────────────────────────────

  defp transform_point(el) do
    pos = make_pos(el)
    children = named_children(el)

    args =
      children
      |> Enum.map(&transform_to_arg/1)
      |> clean_args()

    case extract_lat_lng(args) do
      {:ok, lat, lng} -> {:point, lat, lng, pos}
      :error -> {:point, args, nil, pos}
    end
  end

  defp transform_geometry(el, type) do
    pos = make_pos(el)
    children = named_children(el)

    args =
      children
      |> Enum.map(&transform_to_arg/1)
      |> clean_args()

    items = extract_posargs(args)
    {type, items, pos}
  end

  defp transform_bbox(el) do
    pos = make_pos(el)
    children = named_children(el)

    args =
      children
      |> Enum.map(&transform_to_arg/1)
      |> clean_args()

    case extract_bbox_coords(args) do
      {:ok, s, w, n, e} -> {:bbox, s, w, n, e, pos}
      :error -> {:bbox, args, nil, nil, nil, pos}
    end
  end

  # ── List ────────────────────────────────────────────────────────

  defp transform_list(el) do
    pos = make_pos(el)
    items = named_children(el) |> Enum.map(&transform_expression/1)
    {:list, items, pos}
  end

  # ── Parenthesized expression ────────────────────────────────────

  defp transform_paren(el) do
    child = first_named_child(el)
    transform_expression(child)
  end

  # ── Literals ────────────────────────────────────────────────────

  defp transform_number(el) do
    pos = make_pos(el)
    text = text_content(el) |> String.trim()

    value =
      if String.contains?(text, ".") do
        String.to_float(text)
      else
        String.to_integer(text)
      end

    {:number, value, pos}
  end

  defp transform_string(el) do
    pos = make_pos(el)
    value = extract_string_text(el)
    {:string, value, pos}
  end

  defp transform_boolean(el) do
    pos = make_pos(el)
    text = text_content(el) |> String.trim()
    value = text == "true"
    {:bool, value, pos}
  end

  defp transform_atom(el) do
    pos = make_pos(el)
    # The atom node contains an identifier child — use that for the name
    id_el = Enum.find(named_children(el), fn c -> elem_name(c) == :identifier end)

    name =
      if id_el do
        text_content(id_el) |> String.trim()
      else
        # Fallback: extract from full text
        text_content(el)
        |> String.trim()
        |> String.replace_prefix(":", "")
        |> String.trim()
      end

    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    atom = Map.get_lazy(@literal_atoms, name, fn -> String.to_atom(name) end)
    {:atom, atom, pos}
  end

  defp transform_bare_identifier(el) do
    pos = make_pos(el)
    # bare_identifier wraps an identifier
    child = first_named_child(el)
    name = if child, do: text_content(child), else: text_content(el)
    {:identifier, name |> String.trim(), pos}
  end

  defp transform_identifier_as_bare(el) do
    pos = make_pos(el)
    name = text_content(el) |> String.trim()
    {:identifier, name, pos}
  end

  # ── Tag filters ─────────────────────────────────────────────────

  defp transform_tag_filter_list(el) do
    named_children(el)
    |> Enum.flat_map(fn child ->
      case elem_name(child) do
        :tag_filter -> [transform_tag_filter(child)]
        :regex_key_filter -> [transform_regex_key_filter(child)]
        _ -> []
      end
    end)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp transform_tag_filter(el) do
    key_el = field_child(el, "key")
    value_el = field_child(el, "value")
    key = text_content(key_el)

    case elem_name(value_el) do
      :tag_exists ->
        {:exists, key}

      :tag_not_exists ->
        {:not_exists, key}

      :tag_regex ->
        str_el = first_named_child(value_el)
        {:regex, key, extract_string_text(str_el)}

      :tag_regex_i ->
        str_el = first_named_child(value_el)
        {:regex_i, key, extract_string_text(str_el)}

      :tag_neq ->
        str_el = first_named_child(value_el)
        {:neq, key, extract_string_text(str_el)}

      :tag_not_regex ->
        str_el = first_named_child(value_el)
        {:not_regex, key, extract_string_text(str_el)}

      :string ->
        {:eq, key, extract_string_text(value_el)}

      :number ->
        {:eq_num, key, extract_number_value(value_el)}

      :tag_id_list ->
        nums =
          named_children(value_el)
          |> Enum.filter(fn c -> elem_name(c) == :number end)
          |> Enum.map(&extract_number_value/1)

        {:eq_list, key, nums}

      :bracket_ref ->
        ref = transform_bracket_ref(value_el)
        {:bracket_ref_eq, key, ref}

      :output_bracket_ref ->
        ref = transform_output_bracket_ref(value_el)
        {:bracket_ref_eq, key, ref}

      other ->
        raise "Unknown tag filter value type: #{inspect(other)}"
    end
  end

  defp transform_regex_key_filter(el) do
    key_pattern_el = field_child(el, "key_pattern")
    value_el = field_child(el, "value")
    key_pattern = extract_string_text(key_pattern_el)

    case elem_name(value_el) do
      :tag_exists ->
        {:key_regex_exists, key_pattern}

      :tag_regex ->
        str_el = first_named_child(value_el)
        {:key_value_regex, key_pattern, extract_string_text(str_el)}

      :string ->
        val_str = extract_string_text(value_el)
        {:key_value_regex, key_pattern, "^#{Regex.escape(val_str)}$"}

      _ ->
        {:key_regex_exists, key_pattern}
    end
  end

  # ── Filter expressions ──────────────────────────────────────────

  defp transform_filter_expression(el) do
    child = first_named_child(el)

    if child do
      transform_expression(child)
    else
      # Leaf node — probably a number/string/bool within filter context
      text = text_content(el) |> String.trim()

      cond do
        text =~ ~r/^\d/ -> transform_number(el)
        String.starts_with?(text, "\"") -> transform_string(el)
        text in ["true", "false"] -> transform_boolean(el)
        true -> {:identifier, text, make_pos(el)}
      end
    end
  end

  defp transform_filter_binop(el) do
    children = named_children(el)
    _pos = make_pos(el)

    # Binary expression has left, operator (anonymous), right children
    # The operator is embedded as anonymous text between named children
    case children do
      [left, right] ->
        op = extract_operator(el)
        left_ast = transform_expression(left)
        right_ast = transform_expression(right)
        {:bin_op, op, left_ast, right_ast, extract_node_pos(left_ast)}

      [single] ->
        transform_expression(single)

      _ ->
        # Fold multiple operands (chained operators)
        fold_filter_binop_children(children, el)
    end
  end

  defp fold_filter_binop_children(children, el) do
    # For chained operations like a + b + c, the CST may have [a, b, c]
    # with operators embedded as text nodes
    op = extract_operator(el)

    case children do
      [] ->
        {:identifier, "", make_pos(el)}

      [single] ->
        transform_expression(single)

      [first | rest] ->
        left = transform_expression(first)

        Enum.reduce(rest, left, fn right_el, acc ->
          right = transform_expression(right_el)
          {:bin_op, op, acc, right, extract_node_pos(acc)}
        end)
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp extract_operator(el) do
    # Read the text content between named children to find the operator
    raw = raw_text_between_named(el)

    cond do
      String.contains?(raw, "||") -> :or
      String.contains?(raw, "&&") -> :and
      String.contains?(raw, "!=") -> :neq
      String.contains?(raw, "==") -> :eq
      String.contains?(raw, ">=") -> :gte
      String.contains?(raw, "<=") -> :lte
      String.contains?(raw, ">") -> :gt
      String.contains?(raw, "<") -> :lt
      String.contains?(raw, "*") -> :mul
      String.contains?(raw, "/") -> :div
      String.contains?(raw, "+") -> :add
      String.contains?(raw, "-") -> :sub
      true -> :unknown
    end
  end

  defp transform_filter_unary(el) do
    pos = make_pos(el)
    children = named_children(el)
    raw = raw_text_before_first_named(el)

    op =
      cond do
        String.contains?(raw, "!") -> :not
        String.contains?(raw, "-") -> :neg
        true -> :not
      end

    case children do
      [operand] ->
        {:unary_op, op, transform_expression(operand), pos}

      _ ->
        {:unary_op, op, nil, pos}
    end
  end

  defp transform_filter_paren(el) do
    child = first_named_child(el)
    transform_expression(child)
  end

  # credo:disable-for-lines:70 Credo.Check.Refactor.CyclomaticComplexity
  # credo:disable-for-lines:70 Credo.Check.Refactor.ABCSize
  defp transform_filter_function_call(el) do
    pos = make_pos(el)
    # The function name is embedded as anonymous text before the "(" token
    # Extract it from the raw text of the element
    all_text = text_content(el) |> String.trim()

    func_name =
      case Regex.run(~r/^([a-zA-Z_][a-zA-Z0-9_]*)/, all_text) do
        [_, name] -> name
        _ -> all_text
      end

    children = named_children(el)

    case func_name do
      name when name in ["number", "is_number"] ->
        arg = if children != [], do: transform_expression(hd(children)), else: nil
        # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
        {:coerce_func, String.to_atom(name), arg, pos}

      name when name in ["starts_with", "ends_with", "str_contains"] ->
        {arg1, arg2} =
          case children do
            [a, b] -> {transform_expression(a), transform_expression(b)}
            [a] -> {transform_expression(a), nil}
            _ -> {nil, nil}
          end

        # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
        {:str_func, String.to_atom(name), arg1, arg2, pos}

      "size" ->
        arg = if children != [], do: transform_expression(hd(children)), else: nil
        {:str_func, :size, arg, nil, pos}

      "distance" ->
        point_el = Enum.find(children, fn c -> elem_name(c) == :point_constructor end)

        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        if point_el do
          {:point, lat, lng, _} = transform_point(point_el)
          {:geom_func, :distance, {lat, lng}, pos}
        else
          {:geom_func, :distance, nil, pos}
        end

      name when name in ["id", "type", "lat", "lon"] ->
        # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
        {:prop_access, String.to_atom(name), pos}

      name when name in ["is_closed", "elevation", "length", "area"] ->
        # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
        {:geom_func, String.to_atom(name), pos}

      _ ->
        # Unknown function — try to transform as expression
        if children != [],
          do: transform_expression(hd(children)),
          else: {:identifier, func_name, pos}
    end
  end

  # ── Filter expression functions ─────────────────────────────────

  defp transform_tag_access(el) do
    pos = make_pos(el)
    str_el = Enum.find(named_children(el), fn c -> elem_name(c) == :string end)
    key = extract_string_text(str_el)
    {:tag_access, key, pos}
  end

  defp transform_prop_accessor(el) do
    pos = make_pos(el)
    name_el = field_child(el, "name")
    name = text_content(name_el) |> String.trim()
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    {:prop_access, String.to_atom(name), pos}
  end

  defp transform_geom_function(el) do
    pos = make_pos(el)
    name_el = field_child(el, "name")
    name = text_content(name_el) |> String.trim()
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    {:geom_func, String.to_atom(name), pos}
  end

  defp transform_coerce_function(el) do
    pos = make_pos(el)
    name_el = field_child(el, "name")
    name = text_content(name_el) |> String.trim()
    children = named_children(el)
    arg_el = Enum.find(children, fn c -> get_field(c) != "name" end)
    arg = if arg_el, do: transform_expression(arg_el), else: nil
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    {:coerce_func, String.to_atom(name), arg, pos}
  end

  defp transform_string_function(el) do
    pos = make_pos(el)
    name_el = field_child(el, "name")
    name = text_content(name_el) |> String.trim()
    children = named_children(el) |> Enum.reject(fn c -> get_field(c) == "name" end)

    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    func_atom = String.to_atom(name)

    case children do
      [arg1, arg2] ->
        {:str_func, func_atom, transform_expression(arg1), transform_expression(arg2), pos}

      [arg1] ->
        {:str_func, func_atom, transform_expression(arg1), nil, pos}

      _ ->
        {:str_func, func_atom, nil, nil, pos}
    end
  end

  defp transform_distance_function(el) do
    pos = make_pos(el)
    children = named_children(el)
    point_el = Enum.find(children, fn c -> elem_name(c) == :point_constructor end)

    if point_el do
      {:point, lat, lng, _point_pos} = transform_point(point_el)
      {:geom_func, :distance, {lat, lng}, pos}
    else
      {:geom_func, :distance, nil, pos}
    end
  end

  defp transform_size_function(el) do
    pos = make_pos(el)
    children = named_children(el)

    case children do
      [arg] -> {:str_func, :size, transform_expression(arg), nil, pos}
      _ -> {:str_func, :size, nil, nil, pos}
    end
  end

  defp transform_dataset_source(el) do
    slugs = transform_dataset_slugs(el)
    {:dataset, slugs}
  end

  defp transform_kwarg(el) do
    key = text_content(field_child(el, "key"))
    value = transform_expression(field_child(el, "value"))
    {:kwarg, key, value}
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp to_method_atom(name), do: Map.get(@method_atoms, name, name)

  defp extract_string_text(el) do
    # String nodes contain the raw text including quotes: "foo"
    # We need to strip the quotes and unescape
    raw = text_content(el)
    # Remove surrounding quotes
    inner =
      raw
      |> String.trim()
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")

    # Unescape common escapes
    inner
    |> String.replace("\\\\", "\x00BACKSLASH\x00")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\x00BACKSLASH\x00", "\\")
  end

  defp extract_number_value(el) do
    text = text_content(el) |> String.trim()

    if String.contains?(text, ".") do
      String.to_float(text)
    else
      String.to_integer(text)
    end
  end

  defp extract_lat_lng(args) do
    case args do
      [{:posarg, {:number, lat, _}}, {:posarg, {:number, lng, _}}] -> {:ok, lat, lng}
      [{:kwarg, "lat", {:number, lat, _}}, {:kwarg, "lng", {:number, lng, _}}] -> {:ok, lat, lng}
      _ -> :error
    end
  end

  defp extract_bbox_coords(args) do
    case args do
      [
        {:posarg, {:number, s, _}},
        {:posarg, {:number, w, _}},
        {:posarg, {:number, n, _}},
        {:posarg, {:number, e, _}}
      ] ->
        {:ok, s, w, n, e}

      _ ->
        :error
    end
  end

  defp extract_posargs(args) do
    Enum.map(args, fn
      {:posarg, val} -> val
      other -> other
    end)
  end

  defp split_args_opts(args) do
    {posargs, kwargs} = Enum.split_with(args, &match?({:posarg, _}, &1))
    if kwargs != [], do: {[], kwargs}, else: {posargs, []}
  end

  defp extract_node_pos(node) do
    case node do
      {_, _, _, _, _, pos} when is_map(pos) -> pos
      {_, _, _, _, pos} when is_map(pos) -> pos
      {_, _, _, pos} when is_map(pos) -> pos
      {_, _, pos} when is_map(pos) -> pos
      {:chain, inner, _} -> extract_node_pos(inner)
      _ -> %{line: 1, col: 1}
    end
  end

  # ── Position helpers ────────────────────────────────────────────

  defp make_pos(el) do
    # tree-sitter uses 0-based rows, NimbleParsec uses 1-based lines
    srow = get_attr(el, :srow)
    scol = get_attr(el, :scol)

    line = if srow, do: String.to_integer(to_string(srow)) + 1, else: 1
    col = if scol, do: String.to_integer(to_string(scol)) + 1, else: 1
    %{line: line, col: col}
  end

  # ── Error collection ────────────────────────────────────────────

  defp collect_errors(el, source) do
    collect_errors_rec(el, source, [])
  end

  defp collect_errors_rec(el, source, acc) when Record.is_record(el, :xmlElement) do
    acc =
      if elem_name(el) == :ERROR do
        pos = make_pos(el)
        snippet = get_source_snippet(source, pos.line, pos.col)

        [
          %Error{line: pos.line, col: pos.col, message: "unexpected input near: \"#{snippet}\""}
          | acc
        ]
      else
        acc
      end

    xmlElement(el, :content)
    |> Enum.reduce(acc, fn child, inner_acc ->
      if Record.is_record(child, :xmlElement) do
        collect_errors_rec(child, source, inner_acc)
      else
        inner_acc
      end
    end)
  end

  defp collect_errors_rec(_, _, acc), do: acc

  defp split_xml_and_errors(output) do
    # tree-sitter outputs XML first, then error/stat lines on stderr
    # When stderr_to_stdout is true, they're interleaved
    # The XML ends with </sources>, everything after is errors
    case String.split(output, "</sources>", parts: 2) do
      [before, after_xml] ->
        {before <> "</sources>", after_xml}

      [only] ->
        if String.contains?(only, "<?xml") do
          {only, ""}
        else
          {"", only}
        end
    end
  end

  defp extract_missing_errors(stderr, source) do
    # Look for MISSING indicators like: (MISSING ";" [0, 28] - [0, 28])
    Regex.scan(~r/\(MISSING "([^"]*)" \[(\d+), (\d+)\]/, stderr)
    |> Enum.map(fn [_, _expected, row, col] ->
      line = String.to_integer(row) + 1
      col_num = String.to_integer(col) + 1
      snippet = get_source_snippet(source, line, col_num)
      %Error{line: line, col: col_num, message: "unexpected input near: \"#{snippet}\""}
    end)
  end

  defp get_source_snippet(source, line, col) do
    source
    |> String.split("\n")
    |> Enum.at(line - 1, "")
    |> String.slice(max(col - 1, 0), 30)
  end

  # ── XML element helpers ─────────────────────────────────────────

  defp elem_name(el) when Record.is_record(el, :xmlElement) do
    xmlElement(el, :name)
  end

  defp elem_name(_), do: nil

  defp get_attr(el, name) when Record.is_record(el, :xmlElement) do
    xmlElement(el, :attributes)
    |> Enum.find_value(fn attr ->
      if xmlAttribute(attr, :name) == name do
        xmlAttribute(attr, :value)
      end
    end)
  end

  defp get_attr(_, _), do: nil

  defp get_field(el) when Record.is_record(el, :xmlElement) do
    val = get_attr(el, :field)
    if val, do: to_string(val), else: nil
  end

  defp get_field(_), do: nil

  defp named_children(el) when Record.is_record(el, :xmlElement) do
    xmlElement(el, :content)
    |> Enum.filter(&Record.is_record(&1, :xmlElement))
  end

  defp named_children(_), do: []

  defp first_named_child(el) do
    named_children(el) |> List.first()
  end

  defp find_child(el, name) when Record.is_record(el, :xmlElement) do
    named_children(el) |> Enum.find(fn c -> elem_name(c) == name end)
  end

  defp find_child(_, _), do: nil

  defp field_child(el, field_name) when Record.is_record(el, :xmlElement) do
    named_children(el) |> Enum.find(fn c -> get_field(c) == field_name end)
  end

  defp field_child(_, _), do: nil

  defp field_children(el, field_name) when Record.is_record(el, :xmlElement) do
    named_children(el) |> Enum.filter(fn c -> get_field(c) == field_name end)
  end

  defp field_children(_, _), do: []

  defp text_content(el) when Record.is_record(el, :xmlElement) do
    xmlElement(el, :content)
    |> Enum.map_join(fn
      child when Record.is_record(child, :xmlText) ->
        xmlText(child, :value) |> to_string()

      child when Record.is_record(child, :xmlElement) ->
        text_content(child)

      _ ->
        ""
    end)
    |> String.trim()
  end

  defp text_content(_), do: ""

  defp raw_text_between_named(el) when Record.is_record(el, :xmlElement) do
    # Collect text nodes that appear between named element children
    xmlElement(el, :content)
    |> Enum.filter(fn
      child when Record.is_record(child, :xmlText) -> true
      _ -> false
    end)
    |> Enum.map_join(fn child -> xmlText(child, :value) |> to_string() end)
  end

  defp raw_text_before_first_named(el) when Record.is_record(el, :xmlElement) do
    xmlElement(el, :content)
    |> Enum.take_while(fn
      child when Record.is_record(child, :xmlElement) -> false
      _ -> true
    end)
    |> Enum.map_join(fn
      child when Record.is_record(child, :xmlText) -> xmlText(child, :value) |> to_string()
      _ -> ""
    end)
  end
end
