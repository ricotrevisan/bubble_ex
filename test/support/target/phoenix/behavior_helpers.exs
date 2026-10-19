defmodule PhxCheckWeb.BubbleBehavior do
  # credo:disable-for-this-file Credo.Check.Warning.WrongTestFilename
  @moduledoc """
  What the page behavior tests share (test/support/target/phoenix/*_behavior.exs),
  copied by scripts/phoenix_compile_check.sh into the generated project as
  test/support/bubble_behavior.ex.

  A connected page's first load reads its data in a task (WTF-559): the
  join shows the page as its static render does. `live/2` here waits for
  that load (and what waited for it), so a test starts from the page with
  its data. `Phoenix.LiveViewTest.live/2` is the join's own render.
  """

  defmacro __using__(_opts) do
    quote do
      import Phoenix.LiveViewTest, except: [live: 2]
      import PhxCheckWeb.BubbleBehavior, only: [live: 2, hold_first_load: 1, await_held: 0]
    end
  end

  @doc """
  Runs `fun` while a page's first load (its task) is held after its
  first query: `fun` calls `await_held/0` once the page is joined, then
  whatever it sends waits for the data. The task goes on when `fun`
  returns; what `fun` returns is returned.
  """
  def hold_first_load(fun) do
    id = {__MODULE__, make_ref()}
    :telemetry.attach(id, [:phx_check, :repo, :query], &__MODULE__.hold_query/4, self())

    try do
      fun.()
    after
      :telemetry.detach(id)
      receive_held()
    end
  end

  @doc "Waits until a first load is held (`hold_first_load/1`)."
  def await_held do
    receive do
      {:bubble_held, pid} -> send(self(), {:bubble_held_pid, pid})
    after
      5_000 -> raise "no first load was held"
    end
  end

  defp receive_held do
    receive do
      {:bubble_held_pid, pid} ->
        send(pid, :bubble_release)
        receive_held()

      {:bubble_held, pid} ->
        send(pid, :bubble_release)
        receive_held()
    after
      0 -> :ok
    end
  end

  @doc false
  # In a first load's task (LiveView's `start_async/3`), once: waits until
  # released.
  def hold_query(_event, _measurements, _meta, test) do
    if match?({Phoenix.LiveView.Async, _, _}, Process.get(:"$initial_call")) and
         Process.get(:bubble_held) == nil do
      Process.put(:bubble_held, true)
      send(test, {:bubble_held, self()})

      receive do
        :bubble_release -> :ok
      after
        10_000 -> :ok
      end
    end
  end

  @doc "`Phoenix.LiveViewTest.live/2`, then `render_async/2` (at most 5 s)."
  defmacro live(conn, path) do
    quote do
      with {:ok, view, _html} <- Phoenix.LiveViewTest.live(unquote(conn), unquote(path)),
           do: {:ok, view, Phoenix.LiveViewTest.render_async(view, 5_000)}
    end
  end
end
