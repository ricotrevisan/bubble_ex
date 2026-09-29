defmodule BubbleEx.Verify.Replay.ExposureWaiver do
  @moduledoc """
  An app owner's written, expiring consent to anonymous exposure of named
  types on one replay branch, for one run window.

  By default the replay preflight (`BubbleEx.Verify.Replay.Kit.preflight/4`)
  fails closed: a type whose anonymous exposure probe is `:exposed` or
  `:may_leak` refuses the run. A waiver lets exactly those two findings
  pass, for exactly the types it lists, on exactly the target it names,
  until it expires. It never hides them: the probe still runs and its
  actual status, counts and field names stay in the report, with a
  warning per waived type.

  ## Where a waiver comes from

  **The file is the consent record, and nothing proves who wrote it.**
  Any process running as this user can write one, agents included. The
  checks below keep the file private and out of repositories; they do
  not authenticate its author. So a waiver may be written only **after**
  the owner's approval has been recorded (a message, a ticket comment),
  and that approval is quoted, with its date, in `approval_reference`.
  Writing a waiver without that recorded approval is a breach of the
  owner's trust, whatever the driver accepts.

  The driver never writes a waiver, and no function builds one from
  arguments. The app owner, or an operator acting on the owner's recorded
  approval, writes it by hand as a JSON file at a private path outside
  any git checkout, for example
  `~/.local/share/wtf-v5/waivers/<name>.json`:

    * the directory is mode `0700`, the file `0600` with a single link
      (no hard link), both owned by the user running the driver, neither
      a symlink
    * no directory from the file's real (symlink-resolved) directory up to
      `/` holds a `.git` entry (a waiver is never committed)
    * the file is read, then checked again: a file whose inode, size or
      modification time changed between the check and the read is refused

  `load_waiver/1` is the only way to obtain one. Every later use
  (`plan/4`, `record/4`, the preflight, before each run and between
  scenarios) reads the file again and refuses unless it is still private,
  byte-for-byte what was loaded, in scope and unexpired. A waiver cannot
  be forged in memory: a struct built in code, or a loaded one edited,
  does not match its file, and the file is the only authority. Deleting or editing the file revokes the
  waiver at the next check, and the run stops (cleanup still runs).

  ## Format

      {
        "format": "bubble_ex.verify.replay_exposure_waiver",
        "version": 1,
        "app": "acme",
        "branch": "wtfreplay",
        "branch_id": "4k2xq",
        "host": "acme.bubbleapps.io",
        "types": {"user": "user", "custom.task": "task"},
        "issued_at": "2026-01-01T09:00:00Z",
        "expires_at": "2026-01-01T21:00:00Z",
        "approved_by": "Jane Owner (owner of acme)",
        "approval_reference": "2026-01-01, chat: \\"You may expose User and Task anonymously on wtfreplay for today's run\\""
      }

    * `app`, `branch`, `branch_id`, `host` - must equal the run's
      `BubbleEx.Verify.Replay.Target` exactly. `live`, `test` and
      non-`wtfreplay…` branches are refused as in `Target.new/4`
    * `types` - exact type descriptors (as the scenarios name them) to
      their exact Data API paths (as `BubbleEx.Verify.Replay.Names`
      resolves them). No wildcard. Every listed type must be a type of the
      run
    * `issued_at`, `expires_at` - UTC (`Z`) ISO 8601. The window is at
      most 24 hours, and a waiver is refused before `issued_at` and from
      `expires_at` on
    * `approved_by` - who approved, `approval_reference` - free text
      quoting the owner's approval, with its date (`YYYY-MM-DD`)

  Unknown or duplicate keys are refused. The file's SHA-256 is bound into
  the dry-run hash, the report and each run's ledger journal.
  """

  alias BubbleEx.Error
  alias BubbleEx.Verify.Replay
  alias BubbleEx.Verify.Replay.{Names, Target}

  @format "bubble_ex.verify.replay_exposure_waiver"
  @keys ~w(format version app branch branch_id host types issued_at expires_at approved_by approval_reference)
  @max_window 24 * 60 * 60
  @max_bytes 65_536
  @reasons %{
    malformed: :exposure_waiver_malformed,
    unreadable: :exposure_waiver_unreadable,
    not_private: :exposure_waiver_not_private,
    in_repository: :exposure_waiver_in_repository,
    window: :exposure_waiver_window,
    changed: :exposure_waiver_changed,
    scope_mismatch: :exposure_waiver_scope_mismatch,
    not_yet_valid: :exposure_waiver_not_yet_valid,
    expired: :exposure_waiver_expired
  }

  @enforce_keys [
    :path,
    :sha256,
    :app,
    :branch,
    :branch_id,
    :host,
    :types,
    :issued_at,
    :expires_at,
    :approved_by,
    :approval_reference
  ]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            path: String.t(),
            sha256: String.t(),
            app: String.t(),
            branch: String.t(),
            branch_id: String.t(),
            host: String.t(),
            types: %{String.t() => String.t()},
            issued_at: DateTime.t(),
            expires_at: DateTime.t(),
            approved_by: String.t(),
            approval_reference: String.t()
          }

  @doc """
  Loads the owner-written waiver at `path` (absolute). Checks the file's
  privacy and format, not its scope or expiry (`check/5` does, at every
  use). See the moduledoc.
  """
  @spec load_waiver(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def load_waiver(path) when is_binary(path) do
    with :ok <- absolute(path),
         {:ok, stat} <- private(path),
         :ok <- outside_repository(Path.dirname(path)),
         {:ok, bytes} <- read(path),
         :ok <- stable(path, stat, bytes),
         {:ok, fields} <- decode(bytes) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(fields, %{
           path: path,
           sha256: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
         })
       )}
    end
  end

  def load_waiver(_path), do: invalid("an exposure waiver path must be a string", :malformed)

  @doc """
  Checks, at `now` (UTC), that `waiver` still matches its file, names
  exactly `target`, lists only types among `types` with their exact Data
  API paths in `names`, and is inside its window. Reads the file again.
  """
  @spec check(term(), Target.t(), Names.t(), [String.t()], DateTime.t()) ::
          :ok | {:error, Error.t()}
  def check(%__MODULE__{path: path} = waiver, %Target{} = target, names, types, now)
      when is_binary(path) do
    with {:ok, current} <- load_waiver(path),
         :ok <- unchanged(waiver, current),
         :ok <- scope(current, target),
         :ok <- types(current, names, types) do
      window(current, now)
    end
  end

  def check(_waiver, _target, _names, _types, _now),
    do: invalid("not an exposure waiver loaded from its file", :changed)

  @doc false
  # Whether `reason` is one of this module's error reasons.
  @spec reason?(term()) :: boolean()
  def reason?(reason), do: reason in Map.values(@reasons)

  @doc "Whether `waiver` lists the type descriptor `type`."
  @spec waives?(t() | nil, String.t()) :: boolean()
  def waives?(%__MODULE__{types: types}, type), do: Map.has_key?(types, type)
  def waives?(_waiver, _type), do: false

  @doc "The SHA-256 of the waiver's file, or nil."
  @spec sha256(t() | nil) :: String.t() | nil
  def sha256(%__MODULE__{sha256: sha}), do: sha
  def sha256(_), do: nil

  @doc "What a report shows of `waiver` (no path), or nil."
  @spec summary(t() | nil) :: map() | nil
  def summary(%__MODULE__{} = w) do
    %{
      sha256: w.sha256,
      app: w.app,
      branch: w.branch,
      branch_id: w.branch_id,
      host: w.host,
      types: w.types,
      issued_at: DateTime.to_iso8601(w.issued_at),
      expires_at: DateTime.to_iso8601(w.expires_at),
      approved_by: w.approved_by,
      approval_reference: w.approval_reference
    }
  end

  def summary(_), do: nil

  # --- the file ------------------------------------------------------------------------

  defp absolute(path) do
    if Path.type(path) == :absolute and Path.expand(path) == path,
      do: :ok,
      else: invalid("an exposure waiver path must be absolute and normalized", :malformed)
  end

  defp private(path) do
    with {:ok, uid} <- uid(),
         {:ok, dir} <- File.lstat(Path.dirname(path)),
         {:ok, file} <- File.lstat(path, time: :posix),
         true <- private_stat?(dir, file, uid) do
      {:ok, file}
    else
      {:error, %Error{}} = error ->
        error

      {:error, _posix} ->
        invalid("no exposure waiver at that path", :unreadable)

      false ->
        invalid(
          "an exposure waiver must be a 0600 file with one link in a 0700 directory, " <>
            "both owned by this user",
          :not_private
        )
    end
  end

  @doc false
  # The owner-only rule, on `File.lstat/1` results (so a symlink fails).
  @spec private_stat?(File.Stat.t(), File.Stat.t(), non_neg_integer()) :: boolean()
  def private_stat?(%File.Stat{} = dir, %File.Stat{} = file, uid) do
    match?(%File.Stat{type: :directory, uid: ^uid}, dir) and
      Bitwise.band(dir.mode, 0o7777) == 0o700 and
      match?(%File.Stat{type: :regular, uid: ^uid, links: 1}, file) and
      Bitwise.band(file.mode, 0o7777) == 0o600
  end

  # The file read is the file checked: same inode, size and mtime after
  # the read as at the permission check (and the size is what was read).
  defp stable(path, before, bytes) do
    case File.lstat(path, time: :posix) do
      {:ok, now} ->
        if stable?(before, now, bytes),
          do: :ok,
          else: invalid("the exposure waiver changed while it was read", :changed)

      {:error, _} ->
        invalid("no exposure waiver at that path", :unreadable)
    end
  end

  @doc false
  @spec stable?(File.Stat.t(), File.Stat.t(), binary()) :: boolean()
  def stable?(%File.Stat{} = before, %File.Stat{} = now, bytes) do
    {before.inode, before.major_device, before.size, before.mtime, before.mode, before.uid,
     before.links} ==
      {now.inode, now.major_device, now.size, now.mtime, now.mode, now.uid, now.links} and
      now.size == byte_size(bytes)
  end

  # The effective user ID of this OS process.
  defp uid do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_, uid] <- Regex.run(~r/^Uid:\s+\d+\s+(\d+)/m, status) do
      {:ok, String.to_integer(uid)}
    else
      _ -> uid_from_id()
    end
  end

  defp uid_from_id do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out |> String.trim() |> String.to_integer()}
      _ -> invalid("cannot tell which user runs the driver", :not_private)
    end
  rescue
    _ -> invalid("cannot tell which user runs the driver", :not_private)
  end

  # Walks up from the directory's real path, so a symlinked ancestor
  # cannot hide the checkout it points into.
  defp outside_repository(dir) do
    case real_path(dir) do
      {:ok, real} ->
        ancestors = real |> Path.split() |> Enum.scan(&Path.join(&2, &1))

        if Enum.any?(ancestors, &File.exists?(Path.join(&1, ".git"))),
          do: invalid("an exposure waiver must live outside any git checkout", :in_repository),
          else: :ok

      :error ->
        invalid("cannot resolve the exposure waiver's directory", :unreadable)
    end
  end

  @doc false
  # The path with every symlink resolved (at most 40), `.` and `..` applied
  # to the resolved prefix.
  @spec real_path(String.t()) :: {:ok, String.t()} | :error
  def real_path("/" <> _ = path), do: resolve("/", tl(Path.split(path)), 0)
  def real_path(_), do: :error

  defp resolve(acc, [], _hops), do: {:ok, acc}
  defp resolve(_acc, _rest, hops) when hops > 40, do: :error
  defp resolve(acc, ["." | rest], hops), do: resolve(acc, rest, hops)
  defp resolve(acc, [".." | rest], hops), do: resolve(Path.dirname(acc), rest, hops)

  defp resolve(acc, [segment | rest], hops) do
    candidate = Path.join(acc, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(candidate) do
          {:ok, "/" <> _ = target} -> resolve("/", tl(Path.split(target)) ++ rest, hops + 1)
          {:ok, target} -> resolve(acc, Path.split(target) ++ rest, hops + 1)
          {:error, _} -> :error
        end

      {:ok, _} ->
        resolve(candidate, rest, hops)

      {:error, _} ->
        :error
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= @max_bytes -> {:ok, bytes}
      {:ok, _} -> invalid("the exposure waiver file is too large", :malformed)
      {:error, _} -> invalid("no exposure waiver at that path", :unreadable)
    end
  end

  defp decode(bytes) do
    with {:ok, %Jason.OrderedObject{} = doc} <- Jason.decode(bytes, objects: :ordered_objects),
         {:ok, map} <- object(doc),
         true <- Enum.sort(Map.keys(map)) == Enum.sort(@keys),
         %{"format" => @format, "version" => 1} <- map,
         {:ok, types} <- types_map(map["types"]),
         {:ok, app} <- Replay.app(map["app"]),
         {:ok, branch} <- Replay.branch(map["branch"]),
         {:ok, branch_id} <- Replay.branch_id(map["branch_id"]),
         {:ok, host} <- Replay.host(app, map["host"]),
         {:ok, issued_at} <- utc(map["issued_at"]),
         {:ok, expires_at} <- utc(map["expires_at"]),
         :ok <- max_window(issued_at, expires_at),
         {:ok, approved_by} <- text(map["approved_by"], 2, 200),
         {:ok, reference} <- text(map["approval_reference"], 20, 4000),
         true <- reference =~ ~r/\b\d{4}-\d{2}-\d{2}\b/ do
      {:ok,
       %{
         app: app,
         branch: branch,
         branch_id: branch_id,
         host: host,
         types: types,
         issued_at: issued_at,
         expires_at: expires_at,
         approved_by: approved_by,
         approval_reference: reference
       }}
    else
      {:error, %Error{context: %{reason: :exposure_waiver_window}}} = error -> error
      _ -> malformed()
    end
  end

  # An object with no duplicate key, as a map.
  defp object(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))
    if length(keys) == length(Enum.uniq(keys)), do: {:ok, Map.new(pairs)}, else: :error
  end

  defp types_map(%Jason.OrderedObject{values: [_ | _]} = obj) do
    with {:ok, map} <- object(obj),
         true <- Enum.all?(map, fn {d, p} -> descriptor?(d) and descriptor?(p) end) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  defp types_map(_), do: :error

  # Exact names only: no wildcard, pattern or blank.
  defp descriptor?(value) do
    is_binary(value) and value != "" and byte_size(value) <= 128 and String.valid?(value) and
      not String.match?(value, ~r/[*?\[\]\s\/\\]/u)
  end

  defp utc(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, 0} -> if String.ends_with?(value, "Z"), do: {:ok, dt}, else: :error
      _ -> :error
    end
  end

  defp utc(_), do: :error

  defp max_window(issued_at, expires_at) do
    seconds = DateTime.diff(expires_at, issued_at, :millisecond) / 1000

    if seconds > 0 and seconds <= @max_window,
      do: :ok,
      else:
        invalid(
          "an exposure waiver's window (issued_at to expires_at) is at most 24 hours",
          :window
        )
  end

  defp text(value, min, max) when is_binary(value) do
    trimmed = String.trim(value)

    if String.valid?(trimmed) and String.length(trimmed) >= min and String.length(trimmed) <= max,
      do: {:ok, trimmed},
      else: :error
  end

  defp text(_, _, _), do: :error

  defp malformed,
    do:
      invalid(
        "the exposure waiver is not a valid #{@format} v1 file (see ExposureWaiver)",
        :malformed
      )

  # --- use -----------------------------------------------------------------------------

  defp unchanged(waiver, current) do
    if current == waiver,
      do: :ok,
      else: invalid("the exposure waiver does not match its file", :changed)
  end

  defp scope(w, %Target{} = t) do
    if {w.app, w.branch, w.branch_id, w.host} == {t.app, t.branch, t.branch_id, t.host},
      do: :ok,
      else:
        invalid(
          "the exposure waiver names another app, branch, branch ID or host",
          :scope_mismatch
        )
  end

  defp types(w, names, types) do
    bad =
      for {type, path} <- w.types,
          type not in types or Names.type_path(names, type) != {:ok, path},
          do: type

    if bad == [],
      do: :ok,
      else:
        invalid(
          "the exposure waiver lists types that are not the run's, or with another Data API path",
          :scope_mismatch,
          %{types: Enum.sort(bad)}
        )
  end

  defp window(w, %DateTime{} = now) do
    cond do
      DateTime.compare(now, w.issued_at) == :lt ->
        invalid("the exposure waiver is not valid yet", :not_yet_valid)

      DateTime.compare(now, w.expires_at) != :lt ->
        invalid("the exposure waiver has expired", :expired)

      true ->
        :ok
    end
  end

  defp invalid(message, reason, extra \\ %{}),
    do:
      {:error,
       Error.new(
         :invalid_input,
         message,
         Map.put(extra, :reason, Map.fetch!(@reasons, reason))
       )}
end
