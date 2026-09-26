defmodule BubbleEx.Plan.Residue do
  @moduledoc """
  What a generator cannot lower mechanically, as stack-neutral residue
  entries for `BubbleEx.Plan.build/5`. A task with residue is agent work; a
  task without any closes automatically once generated.

  An entry is `%{subject: id, reason: atom, detail: map}`. `subject` is an
  index symbol ID (`element:…`, `action:…`, `workflow:…`, `api_call:…`), or
  `style:<key>` for a named style. Reasons:

  | reason | subject | from |
  |--------|---------|------|
  | `:uncompiled_expression` | element, page, reusable, workflow, action | `expressions/4`: an expression that does not compile to `BubbleEx.Expression.IR` (or fails the caller's `:check`); `detail.expressions` counts them, `detail.constructs` names what stopped them |
  | `:plugin_element`, `:plugin_action`, `:plugin_event` | element, action, workflow | `index/2`: a plugin type (`detail.plugin` is the plugin ID) |
  | `:unsupported_action` | action | `index/2`: an action type with no known lowering |
  | `:unsupported_event` | workflow | `index/2`: an event type with no known wiring |
  | `:auth_action` | action | `index/2`: log in, sign up and credential actions, lowered by the auth task |
  | `:unresolved_reference` | action, element, workflow | `index/2`: an `:index_unresolved_reference` diagnostic (e.g. a data action whose target type is unknown) |
  | `:dynamic_url` | API call | `index/2`: its URL has no plain host |
  | `:oauth` | API call | `index/2`: its group authenticates users with OAuth |
  | `:malformed_call` | API call | `index/2`: the call or its types registry is not an object |
  | `:runtime_container`, `:no_native_lowering` | element | `frontend/2`: a node `BubbleEx.Frontend.normalize/2` emits as a placeholder (`detail.variant`) |
  | `:trigger_not_normalized` | workflow | `frontend/2`: it listens to an element the normalized frontend does not contain (inside a runtime container), so its event wiring cannot be generated yet (`detail.element`) |
  | `:trigger_dropped` | workflow | `BubbleEx.Plan.build/5`: a dropped plugin's event triggered it and it runs other actions, so it needs a new trigger (`detail.plugin`) |
  | `:reads_dropped_plugin` | any symbol | `BubbleEx.Plan.build/5`: it reads a dropped plugin element's states or a dropped plugin action's result, or names a dropped plugin's data type (`detail.reads`) |
  | `:style_condition`, `:plugin_style` | `style:<key>` | `styles/1`: a named style with a conditional state that is not a pseudo-class, or a plugin element's style |

  `index/2` and `frontend/2` are computed by `BubbleEx.Plan.build/5` itself;
  `expressions/4` and `styles/1` need the app JSON, so their entries are
  passed to it as `residue:`. A target adapter may add its own entries the
  same way (e.g. an expression that compiles to IR but not to its stack).
  """

  alias BubbleEx.{Diagnostic, Error, Expression, Index, Model}
  alias BubbleEx.Expression.{Compiler, Sites}
  alias BubbleEx.Frontend.Normalized
  alias BubbleEx.Frontend.Normalized.Node
  alias BubbleEx.Frontend.Payload
  alias BubbleEx.Index.WorkflowAnalysis

  @type t :: %{subject: String.t(), reason: atom(), detail: map()}

  @reasons ~w(uncompiled_expression plugin_element plugin_action plugin_event unsupported_action
              unsupported_event auth_action unresolved_reference dynamic_url oauth malformed_call
              runtime_container no_native_lowering trigger_not_normalized style_condition
              plugin_style trigger_dropped reads_dropped_plugin)a

  # Events with a known wiring (page, element and backend events).
  @events ~w(ButtonClicked CustomEvent APIEvent DatabaseTriggerEvent ConditionTrue PageLoaded
             InputChanged LoggedIn LoggedOut PopupOpened PopupClosed DoInterval RecurringEvent)

  @auth_actions ~w(SignUp LogIn LogOut OAuthLogin CreateUserAccount ResetPassword SendMagicLink
                   SetTemporaryPassword UpdateCredentials)

  # Style states lowered as pseudo-classes.
  @pseudo_states ~w(is_hovered is_pressed is_focused isnt_valid is_disabled)

  @doc "The residue reasons."
  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  @doc "The auth action types (lowered by the auth task)."
  @spec auth_actions() :: [String.t()]
  def auth_actions, do: @auth_actions

  @doc """
  The plugin ID of an element, action or event type (`"<id>-<code>"`,
  with `_current`/`_test` version suffixes ignored), or nil.
  """
  @spec plugin(term()) :: String.t() | nil
  defdelegate plugin(type), to: BubbleEx.Index.Plugins

  # --- expressions ------------------------------------------------------------

  @doc """
  Residue of the expressions of an app's pages, reusables and workflows
  (`BubbleEx.Expression.Sites`): one `:uncompiled_expression` entry per
  owning symbol whose expressions do not all compile to the stack-neutral
  IR. The owner is the nearest index symbol enclosing the expression
  (element, page, reusable, action or workflow).

  Options:

    * `:check` - `fn ir, site -> [construct] end`, run on each expression
      that compiles to IR; a non-empty list makes it residue too. A target
      adapter uses it to add its own compile stage (see
      `BubbleEx.Target.Elixir`).
    * `:ignore_empty_constraints` - passed to every expression's
      `BubbleEx.Expression.Env` (default nil)
  """
  @spec expressions(map(), Model.t(), Index.t(), keyword()) ::
          {:ok, [t()]} | {:error, Error.t()}
  def expressions(app, model, index, opts \\ [])

  def expressions(app, %Model{} = model, %Index{} = index, opts)
      when is_map(app) and not is_struct(app) do
    check = Keyword.get(opts, :check)
    ignore = Keyword.get(opts, :ignore_empty_constraints)

    with {:ok, sites} <- Sites.collect(app, model) do
      owners = owners(index)

      {:ok,
       sites
       |> Enum.flat_map(fn site ->
         case uncompiled(site, %{site.env | ignore_empty_constraints: ignore}, check) do
           [] -> []
           constructs -> [{owner(site.path, owners), constructs}]
         end
       end)
       |> Enum.reject(&is_nil(elem(&1, 0)))
       |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
       |> Enum.map(fn {subject, lists} ->
         entry(subject, :uncompiled_expression, %{
           expressions: length(lists),
           constructs: lists |> Enum.concat() |> Enum.uniq() |> Enum.sort()
         })
       end)
       |> sort()}
    end
  end

  def expressions(_app, _model, _index, _opts),
    do: {:error, Error.new(:invalid_input, "expected app JSON, its Model and its Index")}

  defp uncompiled(site, env, check) do
    with {:ok, %{ast: ast}} <- Expression.parse(site.raw, schema: env.schema, path: site.path),
         {:ok, %{ir: ir, diagnostics: diags}} <- Compiler.compile(ast, env) do
      cond do
        ir == nil -> constructs(diags)
        check -> check.(ir, site)
        true -> []
      end
    else
      _ -> ["parse_failed"]
    end
  end

  # What stopped compilation, like `BubbleEx.Target.CompileReport`.
  @doc false
  @spec constructs([Diagnostic.t()]) :: [String.t()]
  def constructs(diags) do
    diags
    |> Enum.filter(&(&1.severity != :info or &1.code == :expr_untyped_scope))
    |> Enum.flat_map(fn d ->
      case d.details do
        %{construct: c} -> ["#{d.code}:#{c}"]
        %{constructs: cs} -> Enum.map(cs, &"#{d.code}:#{&1}")
        %{scope: s} -> ["#{d.code}:#{s}"]
        _ -> [Atom.to_string(d.code)]
      end
    end)
    |> case do
      [] -> ["uncompiled"]
      list -> Enum.uniq(list)
    end
  end

  # JSON pointer of each symbol that can own an expression -> its ID.
  defp owners(index) do
    for %{kind: kind} = s <- index.symbols,
        kind in [:page, :reusable, :element, :workflow, :action],
        into: %{},
        do: {s.path, s.id}
  end

  defp owner(path, owners) do
    Enum.find_value(length(path)..1//-1, fn n ->
      Map.get(owners, path |> Enum.take(n) |> Diagnostic.pointer())
    end)
  end

  # --- styles -----------------------------------------------------------------

  @doc """
  Residue of the app's named styles (either key form): a style with a
  conditional state other than a pseudo-class (`is_hovered`, `is_pressed`,
  `is_focused`, `isnt_valid`, `is_disabled`) is `:style_condition`; a
  plugin element's style is `:plugin_style`.
  """
  @spec styles(map()) :: [t()]
  def styles(app) when is_map(app) do
    app
    |> Payload.styles()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, style} -> style_residue(key, style) end)
  end

  defp style_residue(key, style) when is_map(style) do
    subject = "style:" <> to_string(key)

    cond do
      id = plugin(to_string(key)) ->
        [entry(subject, :plugin_style, %{plugin: id})]

      (n = conditional_states(style)) > 0 ->
        [entry(subject, :style_condition, %{states: n})]

      true ->
        []
    end
  end

  defp style_residue(_key, _style), do: []

  defp conditional_states(style) do
    case style["states"] || style["%st"] do
      states when is_map(states) ->
        Enum.count(states, fn {_, state} -> not pseudo_state?(state) end)

      _ ->
        0
    end
  end

  defp pseudo_state?(%{"condition" => %{"type" => "ThisElement", "next" => next}}),
    do: is_map(next) and next["name"] in @pseudo_states and not is_map(next["next"])

  defp pseudo_state?(_), do: false

  # --- index ------------------------------------------------------------------

  @doc """
  Residue the index shows: plugin elements, actions and events, action and
  event types with no known lowering, auth actions, unresolved references
  and API calls that need hand work. `model` gives the API Connector
  groups' authentication.
  """
  @spec index(Index.t(), Model.t()) :: [t()]
  def index(%Index{} = index, %Model{} = model) do
    (Enum.flat_map(index.symbols, &symbol_residue/1) ++
       unresolved(index) ++ api_calls(model))
    |> sort()
  end

  defp symbol_residue(%{kind: :element, id: id, attrs: attrs}) do
    case plugin(attrs[:type]) do
      nil -> []
      p -> [entry(id, :plugin_element, %{plugin: p})]
    end
  end

  defp symbol_residue(%{kind: :action, id: id, attrs: attrs}) do
    type = attrs[:type]

    cond do
      p = plugin(type) ->
        [entry(id, :plugin_action, %{plugin: p})]

      type in @auth_actions ->
        [entry(id, :auth_action, %{type: type})]

      WorkflowAnalysis.action_class(type) == :unknown ->
        [entry(id, :unsupported_action, %{type: type})]

      true ->
        []
    end
  end

  defp symbol_residue(%{kind: :workflow, id: id, attrs: attrs}) do
    type = attrs[:event_type]

    cond do
      p = plugin(type) -> [entry(id, :plugin_event, %{plugin: p})]
      type in @events -> []
      true -> [entry(id, :unsupported_event, %{type: type})]
    end
  end

  defp symbol_residue(_), do: []

  defp unresolved(index) do
    for %{code: :index_unresolved_reference, details: %{references: refs}} <- index.diagnostics,
        %{from: from, reference: kind} <- refs,
        String.starts_with?(from, ["action:", "element:", "workflow:", "page:", "reusable:"]),
        do: entry(from, :unresolved_reference, %{reference: kind})
  end

  defp api_calls(model) do
    for group <- model.connectors,
        call <- group.calls,
        reason = call_reason(group, call),
        do:
          entry(
            BubbleEx.Index.Symbol.id(:api_call, [group.id, call.id]),
            reason,
            %{}
          )
  end

  defp call_reason(_group, %{raw: raw}) when raw != nil, do: :malformed_call
  defp call_reason(_group, %{types: :malformed}), do: :malformed_call

  defp call_reason(group, call) do
    cond do
      is_binary(group.auth) and String.contains?(String.downcase(group.auth), "oauth") -> :oauth
      call.host in [nil, ""] -> :dynamic_url
      true -> nil
    end
  end

  # --- frontend ---------------------------------------------------------------

  @doc """
  Residue of a normalized frontend: every element node
  `BubbleEx.Frontend.normalize/2` emits as a placeholder, as
  `:runtime_container` (popups, floating groups and other runtime overlays,
  whose content it does not normalize) or `:no_native_lowering` (with the
  placeholder's `variant`). Plugin elements are left to `index/2`.

  A workflow listening to an element the normalized frontend does not
  contain (content of a runtime container, which normalization does not
  descend into) is `:trigger_not_normalized`: its body may compile, but
  its event cannot be wired to generated markup.
  """
  @spec frontend(Normalized.t() | nil, Index.t()) :: [t()]
  def frontend(nil, _index), do: []

  def frontend(%Normalized{} = model, %Index{} = index) do
    (model.pages ++ model.reusables)
    |> Enum.flat_map(&nodes/1)
    |> Enum.flat_map(fn node ->
      id = node.source.bubble_id && "element:" <> node.source.bubble_id

      with true <- node.placeholder? and node.kind == :placeholder,
           %{attrs: attrs} <- id && Index.symbol(index, id),
           nil <- plugin(attrs[:type]) do
        [placeholder(id, node.variant)]
      else
        _ -> []
      end
    end)
    |> Enum.concat(triggers(index, normalized_ids(model)))
    |> Enum.uniq()
    |> sort()
  end

  defp triggers(index, present) do
    for %{kind: :workflow, id: id} <- index.symbols,
        %{to: "element:" <> element = to} <- Index.references_from(index, id, [:listens_to]),
        Index.symbol(index, to),
        not MapSet.member?(present, element),
        do: entry(id, :trigger_not_normalized, %{element: to})
  end

  @doc """
  The Bubble IDs of every node (page, reusable, element, placeholder) of a
  normalized frontend.
  """
  @spec normalized_ids(Normalized.t()) :: MapSet.t()
  def normalized_ids(%Normalized{} = model) do
    (model.pages ++ model.reusables)
    |> Enum.flat_map(&nodes/1)
    |> Enum.map(& &1.source.bubble_id)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp placeholder(id, :runtime_overlay), do: entry(id, :runtime_container, %{})
  defp placeholder(id, variant), do: entry(id, :no_native_lowering, %{variant: variant})

  defp nodes(%Node{} = node), do: [node | Enum.flat_map(node.children, &nodes/1)]

  # --- helpers ----------------------------------------------------------------

  @doc false
  @spec entry(String.t(), atom(), map()) :: t()
  def entry(subject, reason, detail), do: %{subject: subject, reason: reason, detail: detail}

  @doc false
  @spec sort([t()]) :: [t()]
  def sort(entries), do: Enum.sort_by(entries, &{&1.subject, &1.reason, inspect(&1.detail)})
end
