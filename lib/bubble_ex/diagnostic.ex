defmodule BubbleEx.Diagnostic do
  @moduledoc """
  The one diagnostic type: BubbleEx reporting that it could not read, parse,
  model or render part of a Bubble app faithfully. The Reader, the expression
  and privacy parsers, the workflow inventory and the schema encoders all emit
  it.

    * `code` - stable atom, listed in `BubbleEx.Diagnostic.Codes`
    * `severity` - `:error | :warning | :info`: how much the owner should care.
      Set by the registry, never by the caller.
    * `outcome` - what happened to the data, also set by the registry:
      `:preserved` (kept verbatim and round-trips, but not modeled),
      `:degraded` (mapped with some loss of meaning) or `:unresolved`
      (could not be mapped, e.g. a missing target).
    * `stage` - `:read | :parse | :model | {:target, format}`
    * `subject` - the Bubble IDs involved, keyed by `:type` (data type),
      `:option_set`, `:external_type` (API Connector type, e.g.
      `"api.apiconnector2.bTa.bTb.obj"`), `:field`, `:rule` and `:workflow`.
      IDs only, never display names.
    * `path` - RFC 6901 JSON pointer into the supplied source
    * `details` - code-specific data (e.g. the unresolved external type)
    * `message` - for people; not part of the diagnostic's identity

  A diagnostic reports a limitation of this tool. It is not a finding about
  the app itself.

  Identity is `{stage, code, subject, path}` (`key/1`). `normalize/1` drops
  duplicates by that key and orders by severity (errors first), subject, code
  and path. Every list of diagnostics BubbleEx returns is normalized.
  """

  alias BubbleEx.Diagnostic.Codes

  @type severity :: :error | :warning | :info
  @type outcome :: :preserved | :degraded | :unresolved
  @type stage :: :read | :parse | :model | {:target, atom()}
  @type subject_key :: :type | :option_set | :external_type | :field | :rule | :workflow
  @type subject :: %{optional(subject_key()) => String.t()}
  @type key :: {stage(), atom(), subject(), String.t()}

  @type t :: %__MODULE__{
          code: atom(),
          severity: severity(),
          outcome: outcome(),
          stage: stage(),
          subject: subject(),
          path: String.t(),
          details: map(),
          message: String.t()
        }

  @enforce_keys [:code, :severity, :outcome, :stage, :path, :message]
  defstruct [:code, :severity, :outcome, :stage, :path, :message, subject: %{}, details: %{}]

  @subject_keys [:type, :option_set, :external_type, :field, :rule, :workflow]
  @severity_rank %{error: 0, warning: 1, info: 2}

  @type option :: {:subject, subject()} | {:details, map()} | {:target, atom()}

  @doc """
  Builds a diagnostic for a registered `code`. `path` is a JSON pointer or a
  list of path segments.

  ## Options

    * `:subject` - Bubble IDs (see the moduledoc)
    * `:details` - code-specific map
    * `:target` - the target format; required exactly for `{:target, _}` codes

  Raises `ArgumentError` for an unregistered code or an invalid subject.
  These are programming errors, not input errors.
  """
  @spec new(atom(), [String.t() | integer()] | String.t(), String.t(), [option()]) :: t()
  def new(code, path, message, opts \\ []) when is_atom(code) and is_binary(message) do
    entry =
      case Codes.fetch(code) do
        {:ok, entry} -> entry
        :error -> raise ArgumentError, "unregistered diagnostic code #{inspect(code)}"
      end

    %__MODULE__{
      code: code,
      severity: entry.severity,
      outcome: entry.outcome,
      stage: stage(entry.stage, Keyword.get(opts, :target), code),
      subject: validate_subject!(Keyword.get(opts, :subject, %{})),
      path: pointer(path),
      details: Keyword.get(opts, :details, %{}),
      message: message
    }
  end

  defp stage(:target, target, _code) when is_atom(target) and not is_nil(target),
    do: {:target, target}

  defp stage(stage, nil, _code) when stage != :target, do: stage

  defp stage(stage, target, code),
    do:
      raise(
        ArgumentError,
        "diagnostic #{inspect(code)} has stage #{inspect(stage)}; got target #{inspect(target)}"
      )

  defp validate_subject!(subject) when is_map(subject) do
    Enum.each(subject, fn
      {key, id} when key in @subject_keys and is_binary(id) -> :ok
      pair -> raise ArgumentError, "invalid diagnostic subject entry #{inspect(pair)}"
    end)

    subject
  end

  @doc "Merges `subject` into each diagnostic; keys the diagnostic already has win."
  @spec put_subject([t()], subject()) :: [t()]
  def put_subject(diagnostics, subject) when is_list(diagnostics) do
    subject = validate_subject!(subject)
    Enum.map(diagnostics, &%{&1 | subject: Map.merge(subject, &1.subject)})
  end

  @doc "The identity of a diagnostic: `{stage, code, subject, path}`."
  @spec key(t()) :: key()
  def key(%__MODULE__{} = d), do: {d.stage, d.code, d.subject, d.path}

  @doc """
  Drops duplicates by `key/1` (keeping the first) and sorts by severity,
  subject, code and path.
  """
  @spec normalize([t()]) :: [t()]
  def normalize(diagnostics) when is_list(diagnostics) do
    diagnostics
    |> Enum.uniq_by(&key/1)
    |> Enum.sort_by(&sort_key/1)
  end

  defp sort_key(d) do
    {Map.fetch!(@severity_rank, d.severity), Enum.map(@subject_keys, &Map.get(d.subject, &1)),
     Atom.to_string(d.code), d.path, stage_to_string(d.stage)}
  end

  @doc "Encodes a list of path segments as an RFC 6901 JSON pointer."
  @spec pointer([String.t() | integer()] | String.t()) :: String.t()
  def pointer(pointer) when is_binary(pointer), do: pointer
  def pointer(path) when is_list(path), do: Enum.map_join(path, "", &("/" <> escape(&1)))

  defp escape(segment),
    do: segment |> to_string() |> String.replace("~", "~0") |> String.replace("/", "~1")

  @doc """
  JSON form: a map with string keys whose values are JSON primitives, so it
  encodes and decodes back to the same shape. `details` is converted
  recursively: keys become strings, atoms other than `true`/`false`/`nil`
  become strings, and tuples become lists. `stage` uses `stage_to_string/1`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = d) do
    %{
      "code" => Atom.to_string(d.code),
      "severity" => Atom.to_string(d.severity),
      "outcome" => Atom.to_string(d.outcome),
      "stage" => stage_to_string(d.stage),
      "subject" => json(d.subject),
      "path" => d.path,
      "details" => json(d.details),
      "message" => d.message
    }
  end

  defp json(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {json_key(k), json(v)} end)

  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json()
  defp json(value) when value in [true, false, nil], do: value
  defp json(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json(value) when is_binary(value) or is_number(value), do: value
  defp json(other), do: inspect(other)

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: to_string(key)

  @doc """
  Encodes a stage as text. The grammar is

      stage  = "read" / "parse" / "model" / "target:" format
      format = the target's format atom, e.g. "ash", "postgres"

  `parse_stage/1` is the inverse.
  """
  @spec stage_to_string(stage()) :: String.t()
  def stage_to_string({:target, target}) when is_atom(target), do: "target:#{target}"
  def stage_to_string(stage) when stage in [:read, :parse, :model], do: Atom.to_string(stage)

  @doc """
  Parses the text form of a stage (see `stage_to_string/1`). Target formats
  must be existing atoms, so untrusted input cannot create atoms.
  """
  @spec parse_stage(String.t()) :: {:ok, stage()} | :error
  def parse_stage("read"), do: {:ok, :read}
  def parse_stage("parse"), do: {:ok, :parse}
  def parse_stage("model"), do: {:ok, :model}

  def parse_stage("target:" <> format) when byte_size(format) > 0 do
    {:ok, {:target, String.to_existing_atom(format)}}
  rescue
    ArgumentError -> :error
  end

  def parse_stage(_), do: :error

  defimpl Jason.Encoder do
    def encode(diagnostic, opts) do
      diagnostic
      |> BubbleEx.Diagnostic.to_map()
      |> BubbleEx.CanonicalJson.ordered()
      |> Jason.Encoder.encode(opts)
    end
  end
end
