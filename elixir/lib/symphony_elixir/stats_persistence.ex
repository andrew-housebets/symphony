defmodule SymphonyElixir.StatsPersistence do
  @moduledoc """
  Persists orchestrator runtime statistics (token totals, session history,
  tool execution stats) to a JSON file so they survive restarts.
  """

  require Logger

  alias SymphonyElixir.Config

  @stats_file "runtime_stats.json"

  @spec stats_path() :: Path.t()
  def stats_path, do: Path.join(Config.workspace_root(), @stats_file)

  @spec save(map()) :: :ok
  def save(stats) do
    path = stats_path()
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(stats, pretty: true))
    File.rename!(tmp, path)
    :ok
  rescue
    error ->
      Logger.warning("Failed to persist stats: #{inspect(error)}")
      :ok
  end

  @spec load() :: {:ok, map() | nil} | {:error, term()}
  def load do
    case File.read(stats_path()) do
      {:ok, contents} ->
        {:ok, Jason.decode!(contents)}

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("Failed to load persisted stats: #{inspect(error)}")
      {:ok, nil}
  end

  @spec delete() :: :ok
  def delete do
    File.rm(stats_path())
    :ok
  end
end
