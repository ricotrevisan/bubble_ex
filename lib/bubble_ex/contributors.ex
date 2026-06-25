defmodule BubbleEx.Contributors do
  @moduledoc """
  Gets the information of a Bubble plugin maker (contributor).
  """

  alias BubbleEx.{Error, HTTP}

  @profile_url "https://bubble.io/contributor/"
  @title_suffix " Contributor Profile | Bubble"

  @doc """
  Fetches a contributor's display name by scraping their public profile page.

  Falls back to the bubble id as the name when the profile is private or the
  page has no usable `<title>`.
  """
  @spec fetch_contributor(String.t()) ::
          {:ok, %{bubble_id: String.t(), name: String.t()}} | {:error, Error.t()}
  def fetch_contributor(contributor_id) do
    url = @profile_url <> contributor_id

    with {:ok, %HTTP.Response{body: body}} <- HTTP.get(url),
         {:ok, html} <- parse_document(body, url),
         {:ok, title} <- extract_title(html, url) do
      {:ok, %{bubble_id: contributor_id, name: contributor_name(title, contributor_id)}}
    end
  end

  defp parse_document(body, url) do
    case Floki.parse_document(body) do
      {:ok, html} ->
        {:ok, html}

      {:error, reason} ->
        {:error, Error.new(:parse_failed, "could not parse HTML", %{url: url, reason: reason})}
    end
  end

  defp extract_title(html, url) do
    case Floki.find(html, "title") do
      [{_tag, _attrs, [title | _]} | _] when is_binary(title) ->
        {:ok, title}

      _ ->
        {:error, Error.new(:parse_failed, "contributor page has no title", %{url: url})}
    end
  end

  defp contributor_name(title, contributor_id) do
    name = String.replace(title, @title_suffix, "")

    # Private profiles render a generic "... | Bubble" title; fall back to the id.
    if String.contains?(name, "|"), do: contributor_id, else: name
  end
end
