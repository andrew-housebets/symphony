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
    path = log_path(issue_identifier)
    iso = if timestamp, do: DateTime.to_iso8601(timestamp), else: nil
    line = Jason.encode!(%{at: iso, text: text}) <> "\n"

    case File.write(path, line, [:append]) do
      :ok -> {:ok, count_lines(path)}
      {:error, _reason} -> :error
    end
  end

  @doc """
  Reads all log entries for an issue. Returns a list of `%{at: string, text: string}`.
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
  Resets (truncates) the log file for an issue. Called when a session restarts.
  """
  @spec reset(String.t()) :: :ok
  def reset(issue_identifier) when is_binary(issue_identifier) do
    path = log_path(issue_identifier)
    File.rm(path)
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
end
