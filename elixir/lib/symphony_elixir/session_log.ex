defmodule SymphonyElixir.SessionLog do
  @moduledoc """
  Append-only log files for codex session stdout, one file per issue.

  Entries are written as newline-delimited JSON to disk so the orchestrator
  doesn't accumulate unbounded lists in memory. The dashboard reads from
  disk on demand when the user expands the stdout panel.
  """

  alias SymphonyElixir.Config

  @log_dir_name "session_logs"

  @doc """
  Returns the log directory path, creating it if needed.
  """
  @spec log_dir() :: Path.t()
  def log_dir do
    path = Path.join(Config.workspace_root(), @log_dir_name)
    File.mkdir_p!(path)
    path
  end

  @doc """
  Returns the log file path for a given issue identifier.
  """
  @spec log_path(String.t()) :: Path.t()
  def log_path(issue_identifier) when is_binary(issue_identifier) do
    safe_name = String.replace(issue_identifier, ~r/[^\w\-]/, "_")
    Path.join(log_dir(), "#{safe_name}.jsonl")
  end

  @doc """
  Appends a stdout entry to the issue's log file. Returns the new line count.
  Non-blocking — writes are fire-and-forget with {:error, _} silently ignored.
  """
  @spec append(String.t(), DateTime.t(), String.t()) :: {:ok, non_neg_integer()} | :error
  def append(issue_identifier, timestamp, text)
      when is_binary(issue_identifier) and is_binary(text) do
    append(issue_identifier, timestamp, text, %{})
  end

  @doc """
  Appends a stdout entry with optional metadata keys (for example:
  `kind`, `event`, `method`, `thread_id`, `turn_id`, `tool`, `item_type`, `details`).
  """
  @spec append(String.t(), DateTime.t() | nil, String.t(), map()) :: {:ok, non_neg_integer()} | :error
  def append(issue_identifier, timestamp, text, metadata)
      when is_binary(issue_identifier) and is_binary(text) and is_map(metadata) do
    path = log_path(issue_identifier)
    iso = if timestamp, do: DateTime.to_iso8601(timestamp), else: nil

    entry =
      %{at: iso, text: text}
      |> Map.merge(normalize_metadata(metadata))
      |> drop_blank_fields()

    line = Jason.encode!(entry) <> "\n"

    case File.write(path, line, [:append]) do
      :ok -> {:ok, count_lines(path)}
      {:error, _reason} -> :error
    end
  end

  @doc """
  Reads all log entries for an issue.
  Returns maps containing at least `%{at: string, text: string}` plus optional metadata.
  """
  @spec read_all(String.t()) :: [map()]
  def read_all(issue_identifier) when is_binary(issue_identifier) do
    path = log_path(issue_identifier)

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:error, _} ->
        []
    end
  end

  @doc """
  Returns the number of lines in the log file without reading the whole file.
  """
  @spec line_count(String.t()) :: non_neg_integer()
  def line_count(issue_identifier) when is_binary(issue_identifier) do
    count_lines(log_path(issue_identifier))
  end

  @doc """
  Appends a session separator to the log file. Called when a session restarts.
  Previous session logs are preserved (append-only).
  """
  @spec reset(String.t()) :: :ok
  def reset(issue_identifier) when is_binary(issue_identifier) do
    path = log_path(issue_identifier)

    if File.exists?(path) do
      separator = Jason.encode!(%{at: DateTime.to_iso8601(DateTime.utc_now()), text: "--- new session ---"}) <> "\n"
      File.write(path, separator, [:append])
    end

    :ok
  end

  defp count_lines(path) do
    case File.open(path, [:read]) do
      {:ok, device} ->
        count = count_lines_stream(device, 0)
        File.close(device)
        count

      {:error, _} ->
        0
    end
  end

  defp count_lines_stream(device, acc) do
    case IO.read(device, :line) do
      :eof -> acc
      {:error, _} -> acc
      _line -> count_lines_stream(device, acc + 1)
    end
  end

  @allowed_metadata_fields ~w(kind event method thread_id turn_id tool item_type details source session_id)a

  defp normalize_metadata(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      with field when is_atom(field) <- normalize_metadata_key(key),
           true <- field in @allowed_metadata_fields,
           normalized_value <- normalize_metadata_value(value),
           false <- is_nil(normalized_value) do
        Map.put(acc, Atom.to_string(field), normalized_value)
      else
        _ -> acc
      end
    end)
  end

  defp normalize_metadata_key(key) when is_atom(key), do: key

  defp normalize_metadata_key(key) when is_binary(key) do
    case key |> String.trim() |> String.downcase() |> String.replace(~r/[^a-z0-9_]/, "_") do
      "kind" -> :kind
      "event" -> :event
      "method" -> :method
      "thread_id" -> :thread_id
      "turn_id" -> :turn_id
      "tool" -> :tool
      "item_type" -> :item_type
      "details" -> :details
      "source" -> :source
      "session_id" -> :session_id
      _ -> nil
    end
  end

  defp normalize_metadata_key(_), do: nil

  defp normalize_metadata_value(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_metadata_value(value) when is_integer(value), do: value
  defp normalize_metadata_value(value) when is_float(value), do: value
  defp normalize_metadata_value(value) when is_boolean(value), do: value

  defp normalize_metadata_value(value) when is_map(value) or is_list(value) do
    inspect(value, pretty: true, limit: 60, printable_limit: 4_000)
  end

  defp normalize_metadata_value(_), do: nil

  defp drop_blank_fields(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc ->
        acc

      {_key, ""}, acc ->
        acc

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end
end
