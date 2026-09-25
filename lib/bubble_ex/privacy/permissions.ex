defmodule BubbleEx.Privacy.Permissions do
  @moduledoc """
  What a privacy rule grants to users matching its condition.

    * `view_all` - view all fields; when false, only `view_fields` are visible
    * `search_for` - find records of this type in searches
    * `view_attachments` - view files uploaded to records of this type
    * `auto_binding` - modify fields through auto-binding; `binding_fields`
      lists the fields that may be modified
    * `create_via_api` / `modify_via_api` / `delete_via_api` - Data API
      permissions, nil when the source does not include them

  Field lists hold field IDs in source order, or nil when absent. Unmodeled
  permission members are kept in `extra` and diagnosed.
  """

  alias BubbleEx.AppTree.Expr.Explanation
  alias BubbleEx.Diagnostic

  @flags %{
    "view_all" => :view_all,
    "search_for" => :search_for,
    "view_attachments" => :view_attachments,
    "auto_binding" => :auto_binding,
    "create_api" => :create_via_api,
    "modify_api" => :modify_via_api,
    "delete_api" => :delete_via_api
  }
  @lists %{"view_fields" => :view_fields, "binding_fields" => :binding_fields}

  defstruct [
    :view_all,
    :search_for,
    :view_attachments,
    :auto_binding,
    :create_via_api,
    :modify_via_api,
    :delete_via_api,
    view_fields: nil,
    binding_fields: nil,
    extra: %{}
  ]

  @type t :: %__MODULE__{
          view_all: boolean() | nil,
          search_for: boolean() | nil,
          view_attachments: boolean() | nil,
          auto_binding: boolean() | nil,
          create_via_api: boolean() | nil,
          modify_via_api: boolean() | nil,
          delete_via_api: boolean() | nil,
          view_fields: [String.t()] | nil,
          binding_fields: [String.t()] | nil,
          extra: map()
        }

  @spec parse(term(), list()) :: {t(), [Diagnostic.t()]}
  def parse(raw, path) when is_map(raw) do
    raw
    |> Enum.sort()
    |> Enum.reduce({%__MODULE__{}, []}, fn {key, value}, {perms, diags} ->
      {perms, more} = member(key, value, perms, path ++ [key])
      {perms, diags ++ more}
    end)
  end

  def parse(raw, path),
    do:
      {%__MODULE__{extra: %{"permissions" => raw}},
       [Diagnostic.new(:invalid_permission, path, "permissions must be an object")]}

  defp member(key, value, perms, path) do
    cond do
      flag = @flags[key] ->
        flag(flag, value, perms, path)

      list = @lists[key] ->
        field_list(list, value, perms, path)

      true ->
        {put_extra(perms, key, value),
         [Diagnostic.new(:unknown_permission, path, "unmodeled permission #{inspect(key)}")]}
    end
  end

  defp flag(flag, value, perms, _path) when is_boolean(value),
    do: {Map.put(perms, flag, value), []}

  defp flag(_flag, value, perms, path),
    do:
      {put_extra(perms, List.last(path), value),
       [Diagnostic.new(:invalid_permission, path, "expected a boolean")]}

  defp field_list(list, value, perms, path) do
    with {:ok, ordered} <- Explanation.ordered(value),
         ids = Enum.map(ordered, &elem(&1, 1)),
         true <- Enum.all?(ids, &is_binary/1) do
      {Map.put(perms, list, ids), []}
    else
      _ ->
        {put_extra(perms, List.last(path), value),
         [Diagnostic.new(:invalid_permission, path, "expected an ordered list of field IDs")]}
    end
  end

  defp put_extra(perms, key, value), do: %{perms | extra: Map.put(perms.extra, key, value)}
end
