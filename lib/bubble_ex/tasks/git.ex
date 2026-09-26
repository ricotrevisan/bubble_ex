defmodule BubbleEx.Tasks.Git do
  @moduledoc """
  Who did what to a task, from git rather than from the labels in its
  state file (WTF-375). A trusted run derives identities from the history
  of `.wtf/tasks/<task>.json`: each commit's author email, and what the
  commit changed in the state.

    * **implementers** - authors of commits that changed a task's
      `agents`, `claim`, `completed_by`, `completed_at` or `evidence`
    * **reviewer** - the author of the commit that recorded the task's
      current `review`

  Only committed history counts: uncommitted changes have no author.
  Author emails are as trustworthy as the repository host makes them
  (protected branches, verified commits); on an unprotected branch they
  are claims like any other, and a trusted run is only as strong as that.
  """

  alias BubbleEx.Tasks.State

  @implementation ~w(agents claim completed_by completed_at evidence)

  @typedoc "`(args) -> {output, status}`: runs `git` in the repository."
  @type cmd :: (list(String.t()) -> {String.t(), non_neg_integer()})

  @doc "A `cmd` running the real `git` in `root`."
  @spec cmd(Path.t()) :: cmd()
  def cmd(root), do: fn args -> System.cmd("git", args, cd: root, stderr_to_stdout: true) end

  @doc """
  `%{implementers: [email], reviews: [{review map, email}]}` of the state
  file of `task`, from its committed history (oldest first).
  """
  @spec identities(cmd(), String.t()) :: %{
          implementers: [String.t()],
          reviews: [{map(), String.t()}]
        }
  def identities(git, task) do
    path = State.path(task)

    case git.(["log", "--reverse", "--format=%H %ae", "--", path]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> String.split(" ", parts: 2) |> List.to_tuple()))
        |> Enum.reduce({nil, %{implementers: [], reviews: []}}, fn {sha, email}, {prev, acc} ->
          now = at(git, sha, path)
          {now, classify(prev, now, email, acc)}
        end)
        |> elem(1)
        |> then(&%{&1 | implementers: &1.implementers |> Enum.uniq() |> Enum.sort()})

      _ ->
        %{implementers: [], reviews: []}
    end
  end

  @doc "The author of the commit that recorded `review` (a state's review, as JSON), or nil."
  @spec review_author(%{reviews: list()}, map() | nil) :: String.t() | nil
  def review_author(_ids, nil), do: nil

  def review_author(%{reviews: reviews}, review) do
    json = State.json(review)
    Enum.find_value(reviews, fn {r, email} -> if r == json, do: email end)
  end

  defp at(git, sha, path) do
    case git.(["show", "#{sha}:./#{path}"]) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp classify(prev, now, email, acc) do
    prev = prev || %{}

    implemented? =
      Enum.any?(
        @implementation,
        &(Map.get(prev, &1) != Map.get(now, &1) and Map.get(now, &1) not in [nil, []])
      )

    reviewed? = now["review"] != nil and prev["review"] != now["review"]

    acc = if implemented?, do: %{acc | implementers: [email | acc.implementers]}, else: acc
    if reviewed?, do: %{acc | reviews: acc.reviews ++ [{now["review"], email}]}, else: acc
  end
end
