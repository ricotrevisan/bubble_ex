defmodule BubbleEx.Expression.Sites do
  @moduledoc """
  Every expression in an app's pages, reusable elements and workflows, each
  with the `BubbleEx.Expression.Env` it is typed and compiled in.

      {:ok, model} = BubbleEx.Model.build(app)
      {:ok, sites} = BubbleEx.Expression.Sites.collect(app, model)

      for site <- sites do
        {:ok, %{ast: ast}} = BubbleEx.Expression.parse(site.raw, schema: site.env.schema)
        BubbleEx.Expression.Compiler.compile(ast, site.env)
      end

  A site is an outermost expression: a text expression, or a source with a
  chain of operators (the roots the privacy acceptance test counts).
  Expressions nested inside one are part of it.

    * on a page, reusable element or element (its properties, conditions,
      states), the host is that node: `This element`, `Parent group` and the
      current cell are found from it in the element tree
    * in a workflow (its event and actions), the host is the element the
      event is attached to, else the workflow's page or reusable; a
      database trigger's workflow knows the triggering type
      (`trigger_type`), and every step knows the result types of the
      workflow's data steps (`steps`)

  `kind` is `:element` or `:workflow`; `subject` has the workflow's Bubble
  ID for workflow sites. Order is by source path.
  """

  alias BubbleEx.{Error, Expression}
  alias BubbleEx.Expression.{Env, Tree, Typing}
  alias BubbleEx.Model
  alias BubbleEx.Workflows.Source

  @enforce_keys [:raw, :path, :env, :kind]
  defstruct [:raw, :path, :env, :kind]

  @type t :: %__MODULE__{raw: term(), path: list(), env: Env.t(), kind: :element | :workflow}

  @sections [
    {~w(pages %p3), :page},
    {["mobile_views"], :page},
    {~w(element_definitions %ed), :reusable}
  ]
  @children ~w(elements %el)
  @workflows ~w(workflows %wf)

  @doc """
  Collects the sites of decoded app JSON. `tree` defaults to
  `BubbleEx.Expression.Tree.build(app)`.
  """
  @spec collect(map(), Model.t(), Tree.t() | nil) :: {:ok, [t()]} | {:error, Error.t()}
  def collect(app, model, tree \\ nil)

  def collect(app, %Model{} = model, tree) when is_map(app) and not is_struct(app) do
    env = Env.new(model, tree: tree || Tree.build(app))

    owners =
      for {sections, _kind} <- @sections,
          section <- sections,
          owners = Map.get(app, section),
          is_map(owners),
          {key, owner} <- Enum.sort(owners),
          is_map(owner),
          site <- owner(owner, [section, key], env),
          do: site

    api =
      case Map.get(app, "api") do
        workflows when is_map(workflows) or is_list(workflows) ->
          workflows(workflows, ["api"], nil, env)

        _ ->
          []
      end

    {:ok, Enum.sort_by(owners ++ api, & &1.path)}
  end

  def collect(_app, _model, _tree),
    do: {:error, Error.new(:invalid_input, "expected decoded app JSON and a BubbleEx.Model")}

  defp owner(owner, path, env) do
    id = text(Source.value(owner, ~w(id %id))) || List.last(path)
    node_sites(owner, path, id, env)
  end

  defp node_sites(raw, path, id, env) do
    own = Map.drop(raw, @children ++ @workflows)

    elements =
      case Source.get(raw, @children) do
        {key, children} ->
          for {ckey, child} <- Source.entries(children),
              is_map(child),
              cid = text(Source.value(child, ~w(id %id))) || to_string(ckey),
              site <- node_sites(child, path ++ [key, ckey], cid, env),
              do: site

        nil ->
          []
      end

    wfs =
      case Source.get(raw, @workflows) do
        {key, workflows} -> workflows(workflows, path ++ [key], id, env)
        nil -> []
      end

    sites(own, path, %{env | host: id}, :element) ++ elements ++ wfs
  end

  defp workflows(workflows, path, host, env) do
    for {key, workflow} <- Source.entries(workflows),
        is_map(workflow),
        site <- workflow(workflow, path ++ [key], host, env),
        do: site
  end

  defp workflow(raw, path, host, env) do
    props =
      case Source.value(raw, ~w(properties %p)) do
        props when is_map(props) -> props
        _ -> %{}
      end

    id = text(Source.value(raw, ~w(id %id))) || to_string(List.last(path))
    type = Source.value(raw, ~w(type %x))
    trigger = if type == "DatabaseTriggerEvent", do: text(props["data_trigger_type"])
    element = text(props["element_id"])
    host = if element && Tree.node(env.tree, element), do: element, else: host

    env = %{env | host: host, trigger_type: trigger, subject: %{workflow: id}}

    {actions, akey} =
      case Source.get(raw, ~w(actions %a)) do
        {key, actions} -> {Source.entries(actions), key}
        nil -> {[], nil}
      end

    env = %{env | steps: steps(actions, env)}
    event = Map.drop(raw, ["actions", "%a"])

    sites(event, path, env, :workflow) ++
      Enum.flat_map(actions, fn {key, action} ->
        sites(action, path ++ [akey, key], env, :workflow)
      end)
  end

  # Result types of data steps, by action Bubble ID.
  defp steps(actions, env) do
    for {_key, action} <- actions,
        is_map(action),
        id = text(Source.value(action, ~w(id %id))),
        id != nil,
        type = step_type(action, env),
        type != nil,
        into: %{},
        do: {id, type}
  end

  defp step_type(action, env) do
    props =
      case Source.value(action, ~w(properties %p)) do
        props when is_map(props) -> props
        _ -> %{}
      end

    case Source.value(action, ~w(type %x)) do
      "NewThing" -> text(props["thing_type"])
      "ChangeThing" -> expression_type(props["to_change"], env)
      "ChangeListOfThings" -> listed(text(props["type_to_change"]))
      "CopyListOfThings" -> expression_type(props["to_copy"], env)
      type when type in ~w(CreateUserAccount SignUp) -> "user"
      _ -> nil
    end
  end

  defp expression_type(raw, env) when is_map(raw) do
    case Expression.parse(raw, schema: env.schema) do
      {:ok, %{ast: ast}} ->
        ast |> Typing.type(env) |> elem(1) |> get_in([:ast, Access.key(:type)])

      {:error, _} ->
        nil
    end
  end

  defp expression_type(_raw, _env), do: nil

  defp listed(nil), do: nil
  defp listed("list." <> _ = type), do: type
  defp listed(type), do: "list." <> type

  # Outermost expressions in `value`, as sites.
  defp sites(value, path, env, kind) do
    value
    |> roots(path, [])
    |> Enum.reverse()
    |> Enum.map(fn {raw, rpath} ->
      %__MODULE__{raw: raw, path: rpath, env: %{env | path: rpath}, kind: kind}
    end)
  end

  defp roots(map, path, acc) when is_map(map) do
    if root?(map) do
      [{map, path} | acc]
    else
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(acc, fn {k, v}, a -> roots(v, path ++ [k], a) end)
    end
  end

  defp roots(list, path, acc) when is_list(list) do
    list |> Enum.with_index() |> Enum.reduce(acc, fn {v, i}, a -> roots(v, path ++ [i], a) end)
  end

  defp roots(_, _, acc), do: acc

  defp root?(map) do
    type = Source.value(map, ~w(type %x))
    next = Source.value(map, ~w(next %n))

    type == "TextExpression" or
      (is_binary(type) and is_map(next) and Source.value(next, ~w(type %x)) == "Message")
  end

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_), do: nil
end
