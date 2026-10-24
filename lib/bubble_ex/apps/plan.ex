defmodule BubbleEx.Apps.Plan do
  @moduledoc """
  Classifies a Bubble app's plan and hosting from live-response evidence.

  Bubble answers "does this name have a live version?" with the first response
  of `https://<id>.bubbleapps.io/` when redirects are not followed (verified
  live on 2026-10-24):

  | evidence                                     | meaning                                       |
  | -------------------------------------------- | --------------------------------------------- |
  | `200`                                        | the app serves its live version: paid         |
  | `301`/`302` to a host outside Bubble         | the customer's own domain: paid               |
  | `302` to `<server>.bubble.is`                | dedicated hosting; the first label is the server |
  | `302` to `bubble.io/live_not_supported`      | no live entitlement; free when the app exists  |
  | `404` while the app exists                   | no live version served, like `live_not_supported` |
  | `400` naming an invalid appname              | the name does not exist                       |
  | 429 / 5xx / timeout / transport error        | no evidence                                   |

  The `live_not_supported` page is also Bubble's answer for names nobody
  claimed, so it only proves a plan together with evidence that the app exists
  (`https://<id>.bubbleapps.io/version-test` serving it). A live `404` is the
  same conclusion for a name that does exist: the live version is simply not
  served. A marketplace template serves its live version exactly like a paid
  app, so that status cannot be read from the response: it is supplied as
  input, never guessed.

  The plan belongs to the app, so `:live` must always be the response of the
  **live** origin, never of a version URL. Bubble serves `/version-<name>`
  (including `/version-test`) for free apps too, so a version URL's own status
  says nothing about the plan: the caller reads it from the same origin with
  the version segment removed, then fetches the version URL it was given.

  `classify/1` is pure: no HTTP, no application environment, no side effects.
  Precedence is template > dedicated > free > paid, and a `301`/`302` to a
  `bubble.io` page other than `live_not_supported` is no evidence at all.
  Template status replaces the plan only: the dedicated hosting the live
  response proves is still reported.

  **Paid is never a default.** A response that does not prove a live app leaves
  `:plan` as `nil` and says in `:basis` which evidence was missing: an unknown
  plan is honest, a paid plan nobody can confirm is not.

  ## Examples

      iex> BubbleEx.Apps.Plan.classify(%{
      ...>   live: %{status: 200, location: nil},
      ...>   exists: :unknown,
      ...>   template?: false
      ...> })
      %{plan: :paid, basis: "live 200", dedicated_server: nil, base_url: nil}

      iex> BubbleEx.Apps.Plan.classify(%{
      ...>   live: %{status: 429, location: nil},
      ...>   exists: :unknown,
      ...>   template?: false
      ...> })
      %{plan: nil, basis: "no evidence (live 429)", dedicated_server: nil, base_url: nil}
  """

  @redirect_statuses [301, 302, 303, 307, 308]
  @bubble_domains ["bubble.io", "bubbleapps.io", "bubble.is"]

  @typedoc "Whether the app is known to exist (`version-test` serving it, or its bundle)."
  @type exists :: :yes | :no | :unknown

  @typedoc """
  The app's live response: a status and its `location` header, or the transport
  error that stopped the request.
  """
  @type live :: %{status: non_neg_integer(), location: String.t() | nil} | {:error, term()}

  @typedoc """
  Everything the classification reads. `:template?` is supplied by the caller
  (a marketplace lookup), never fetched.
  """
  @type evidence :: %{live: live(), exists: exists(), template?: boolean()}

  @type plan :: :template | :dedicated | :free | :paid | nil

  @typedoc """
  A classification: the plan (or `nil` when the evidence proves nothing), the
  short stable `:basis` it rests on, and — for dedicated hosting — the server
  and the base URL of the instance.
  """
  @type t :: %{
          plan: plan(),
          basis: String.t(),
          dedicated_server: String.t() | nil,
          base_url: String.t() | nil
        }

  @doc """
  Classifies an app's plan from its live response and the app's existence.

  Template status wins over everything else, but only when the app is not
  known to be missing.
  """
  @spec classify(evidence()) :: t()
  def classify(%{live: live, exists: exists} = evidence) do
    if Map.get(evidence, :template?) == true and exists != :no do
      template(live)
    else
      classify_live(live, exists)
    end
  end

  @doc """
  Whether a live response redirects to Bubble's `live_not_supported` page.

  That page means the name has no live entitlement: it is Bubble's own answer
  for free apps and for names nobody claimed. It proves a plan only once the
  app is known to exist.
  """
  @spec live_not_supported?(live()) :: boolean()
  def live_not_supported?(%{status: status, location: location})
      when status in @redirect_statuses do
    case destination(location) do
      nil -> false
      destination -> live_not_supported_destination?(destination)
    end
  end

  def live_not_supported?(_live), do: false

  defp classify_live({:error, reason}, _exists), do: no_evidence(reason_label(reason))

  defp classify_live(%{status: status}, _exists) when status in 200..299 do
    classification(:paid, "live #{status}")
  end

  defp classify_live(%{status: status, location: location}, exists)
       when status in @redirect_statuses do
    classify_redirect(status, location, exists)
  end

  defp classify_live(%{status: 400}, _exists), do: no_plan("live 400 invalid appname")

  defp classify_live(%{status: 404}, :yes),
    do: classification(:free, "live 404; version-test serves the app")

  defp classify_live(%{status: 404}, _exists), do: no_plan("live 404 not found")
  defp classify_live(%{status: status}, _exists), do: no_evidence("live #{status}")

  defp classify_redirect(status, location, exists) do
    case destination(location) do
      nil ->
        no_evidence("live #{status} without a location")

      %{host: host} = destination ->
        cond do
          bubble_is?(host) -> dedicated(status, destination)
          live_not_supported_destination?(destination) -> free(status, exists)
          bubble_host?(host) -> no_evidence("live #{status} -> #{host}")
          true -> classification(:paid, "live #{status} -> custom domain")
        end
    end
  end

  defp dedicated(status, %{host: host, url: url}) do
    %{
      plan: :dedicated,
      basis: "live #{status} -> #{host}",
      dedicated_server: host |> String.split(".") |> List.first(),
      base_url: base_url(url)
    }
  end

  # A template's plan comes from the owner, but its hosting still comes from the
  # live response: a template on a dedicated instance is still dedicated.
  defp template(live) do
    case dedicated_hosting(live) do
      nil ->
        classification(:template, "marketplace template")

      %{dedicated_server: server, base_url: base} ->
        %{
          plan: :template,
          basis: "marketplace template",
          dedicated_server: server,
          base_url: base
        }
    end
  end

  defp dedicated_hosting(%{status: status, location: location})
       when status in @redirect_statuses do
    case destination(location) do
      %{host: host} = destination -> if bubble_is?(host), do: dedicated(status, destination)
      nil -> nil
    end
  end

  defp dedicated_hosting(_live), do: nil

  defp free(status, :yes) do
    classification(:free, "live #{status} live_not_supported; version-test serves the app")
  end

  defp free(status, _exists) do
    no_evidence("live #{status} live_not_supported; the app is not confirmed")
  end

  # The rule `BubbleEx.Apps.process_redirect_result/3` uses: the version
  # segment that names the served version is not part of the instance's base.
  defp base_url(url) do
    url |> String.split(~r{/version-[^/]*}, parts: 2) |> List.first()
  end

  defp classification(plan, basis) do
    %{plan: plan, basis: basis, dedicated_server: nil, base_url: nil}
  end

  defp no_plan(basis), do: classification(nil, basis)

  defp no_evidence(reason), do: no_plan("no evidence (#{reason})")

  defp destination(location) when is_list(location), do: destination(List.first(location))

  defp destination(location) when is_binary(location) do
    case URI.parse(location) do
      %URI{host: host} = uri when is_binary(host) and host != "" ->
        %{host: String.downcase(host), path: uri.path || "", url: location}

      _ ->
        nil
    end
  end

  defp destination(_location), do: nil

  defp live_not_supported_destination?(%{host: host, path: path}) do
    host_under?(host, "bubble.io") and String.starts_with?(path, "/live_not_supported")
  end

  defp bubble_is?(host), do: host_under?(host, "bubble.is")

  defp bubble_host?(host), do: Enum.any?(@bubble_domains, &host_under?(host, &1))

  defp host_under?(host, domain), do: host == domain or String.ends_with?(host, "." <> domain)

  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label(_reason), do: "transport error"
end
