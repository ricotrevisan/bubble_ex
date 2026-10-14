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
      workflow's earlier steps (`steps`): a created or changed thing, a
      changed list, a signed-up user, a custom event's return values
      (`custom_events`), or an API Connector call's API type (WTF-533); in
      Bubble order, so a step that changes an earlier step's result has
      that result's type
    * searches run on a page (`Env.searches: :page`) except in a backend
      workflow and in a page workflow's server-side action (`:backend`,
      `action_env/2`)

  `kind` is `:element` or `:workflow`; `subject` has the workflow's Bubble
  ID for workflow sites. Order is by source path.
  """

  alias BubbleEx.{Error, Expression}
  alias BubbleEx.Expression.{Env, Tree, Typing}
  alias BubbleEx.Index.WorkflowAnalysis
  alias BubbleEx.Model
  alias BubbleEx.Workflows.{Lowering, Source}

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
    env = Env.new(model, tree: tree || Tree.build(app), custom_events: custom_events(app))

    owners =
      for {sections, _kind} <- @sections,
          section <- sections,
          owners = Map.get(app, section),
          is_map(owners),
          {key, owner} <- Enum.sort(owners),
          is_map(owner),
          site <- owner(owner, [section, key], %{env | searches: :page}),
          do: site

    api =
      case Map.get(app, "api") do
        workflows when is_map(workflows) or is_list(workflows) ->
          workflows(workflows, ["api"], nil, %{env | searches: :backend})

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
    env = workflow_env(raw, path, host, env)

    {actions, akey} =
      case Source.get(raw, ~w(actions %a)) do
        {key, actions} -> {Source.entries(actions), key}
        nil -> {[], nil}
      end

    event = Map.drop(raw, ["actions", "%a"])

    sites(event, path, env, :workflow) ++
      Enum.flat_map(actions, fn {key, action} ->
        sites(action, path ++ [akey, key], action_env(action, env), :workflow)
      end)
  end

  @doc """
  The environment of one action of a workflow compiled in `env`. A page
  workflow's server-side action (`BubbleEx.Index.WorkflowAnalysis`: a
  create, change, delete, bulk change, schedule, …) runs its searches with
  the backend rule (`searches: :backend`): an empty constraint value
  matches nothing, whatever `ignore_empty_constraints` says. Stricter than
  Bubble on purpose: Bubble drops the constraint there with the option
  true (replay 2026-10-07), so a delete or bulk change with an empty input
  would reach every record the user can read.
  """
  @spec action_env(term(), Env.t()) :: Env.t()
  def action_env(action, %Env{searches: :page} = env) when is_map(action) do
    if WorkflowAnalysis.action_class(Source.value(action, ~w(type %x))) == :server,
      do: %{env | searches: :backend},
      else: env
  end

  def action_env(_action, %Env{} = env), do: env

  @doc """
  The `BubbleEx.Expression.Env` the expressions of the workflow `raw` (at
  `path`, on the page, reusable or element `host`, nil for a backend
  workflow) are typed and compiled in: its host element, trigger type,
  subject and step result types. `env` is the app's base environment.
  """
  @spec workflow_env(map(), list(), String.t() | nil, Env.t()) :: Env.t()
  def workflow_env(raw, path, host, %Env{} = env) when is_map(raw) do
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

    actions =
      case Source.get(raw, ~w(actions %a)) do
        {_key, actions} -> Lowering.ordered(actions)
        nil -> []
      end

    %{env | steps: steps(actions, env)}
  end

  # Result types of the steps, by action Bubble ID, in Bubble order: a
  # step's own expressions (what "Make changes to a thing" changes) are
  # typed with the steps before it.
  defp steps(actions, env) do
    Enum.reduce(actions, %{}, fn {_key, action}, acc ->
      with true <- is_map(action),
           id when id != nil <- text(Source.value(action, ~w(id %id))),
           type when type != nil <- step_type(action, %{env | steps: acc}) do
        Map.put(acc, id, type)
      else
        _ -> acc
      end
    end)
  end

  # What a step's result is, from its own definition; nil when that is
  # not known (a plugin action, "Schedule API workflow", an API Connector
  # call whose type does not resolve, ...): never guessed.
  defp step_type(action, env) do
    props =
      case Source.value(action, ~w(properties %p)) do
        props when is_map(props) -> props
        _ -> %{}
      end

    step_type(Source.value(action, ~w(type %x)), props, env)
  end

  defp step_type("NewThing", props, _env), do: text(props["thing_type"])
  defp step_type("ChangeThing", props, env), do: expression_type(props["to_change"], env)
  defp step_type("ChangeListOfThings", props, _env), do: listed(text(props["type_to_change"]))
  defp step_type("CopyListOfThings", props, env), do: expression_type(props["to_copy"], env)
  defp step_type(type, _props, _env) when type in ~w(CreateUserAccount SignUp), do: "user"

  defp step_type(type, props, env)
       when type in ~w(TriggerCustomEvent TriggerCustomEventFromReusable),
       do: returns(props, env)

  defp step_type("apiconnector2-" <> ref, _props, env), do: api_result(ref, env.model)

  defp step_type(_type, _props, _env), do: nil

  # An API Connector call's result (WTF-533): the API type it returns (a
  # list of it for a list response), when the Model resolves that type.
  defp api_result(ref, %Model{} = model) do
    case String.split(ref, ".", parts: 2) do
      [group_id, call_id] -> Model.call_result_type(model, group_id, call_id)
      _ -> nil
    end
  end

  defp api_result(_ref, _model), do: nil

  # A custom event's return values: the step's result is read by return
  # ID. A custom event that declares none, or is not found, has no result.
  defp returns(props, env) do
    case Map.get(env.custom_events, text(props["custom_event"])) do
      [_ | _] = returns -> {:returns, returns}
      _ -> nil
    end
  end

  @doc """
  The declared return values (`BubbleEx.Workflows.Lowering.Return`s) of
  every custom event of decoded app JSON, on its pages, reusable elements
  and backend, by the event's Bubble ID (`Env.custom_events`).
  """
  @spec custom_events(map()) :: %{String.t() => [Lowering.Return.t()]}
  def custom_events(app) when is_map(app) do
    owners =
      for {sections, _kind} <- @sections,
          section <- sections,
          owners = Map.get(app, section),
          is_map(owners),
          {_key, owner} <- owners,
          is_map(owner),
          workflow <- node_workflows(owner),
          do: workflow

    api =
      case Map.get(app, "api") do
        workflows when is_map(workflows) or is_list(workflows) ->
          for {key, w} <- Source.entries(workflows), is_map(w), do: {key, w}

        _ ->
          []
      end

    for {key, raw} <- owners ++ api,
        Source.value(raw, ~w(type %x)) == "CustomEvent",
        id = text(Source.value(raw, ~w(id %id))) || text(to_string(key)),
        id != nil,
        into: %{},
        do: {id, Lowering.returns(raw)}
  end

  def custom_events(_app), do: %{}

  defp node_workflows(raw) do
    own =
      case Source.get(raw, @workflows) do
        {_key, workflows} -> for {k, w} <- Source.entries(workflows), is_map(w), do: {k, w}
        nil -> []
      end

    children =
      case Source.get(raw, @children) do
        {_key, children} ->
          for {_k, child} <- Source.entries(children),
              is_map(child),
              w <- node_workflows(child),
              do: w

        nil ->
          []
      end

    own ++ children
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
