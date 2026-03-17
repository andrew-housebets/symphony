defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.Config

  @excluded_entries MapSet.new([".elixir_ls", "tmp"])

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      workspace = workspace_path_for_issue(safe_id)

      with :ok <- validate_workspace_path(workspace),
           {:ok, created?} <- ensure_workspace(workspace),
           :ok <- maybe_bootstrap_source_repo(workspace, issue_context, created?),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace) do
    cond do
      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    workspace = Path.join(Config.workspace_root(), safe_id)

    remove(workspace)
    :ok
  end

  def remove_issue_workspaces(_identifier) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:before_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run")
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)

    case Config.workspace_hooks()[:after_run] do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run")
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Path.join(Config.workspace_root(), safe_id)
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(MapSet.to_list(@excluded_entries), fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?) do
    case created? do
      true ->
        case Config.workspace_hooks()[:after_create] do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create")
        end

      false ->
        :ok
    end
  end

  defp maybe_bootstrap_source_repo(_workspace, _issue_context, false), do: :ok

  defp maybe_bootstrap_source_repo(workspace, issue_context, true) do
    repos = Config.workspace_source_repos_for_labels(Map.get(issue_context, :labels, []))

    case source_repo_checkout_plan(repos) do
      [] ->
        :ok

      checkout_plan ->
        Enum.reduce_while(checkout_plan, :ok, fn %{repo: repo, destination: destination}, _acc ->
          case run_source_repo_clone(repo, workspace, issue_context, destination) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp maybe_run_before_remove_hook(workspace) do
    case File.dir?(workspace) do
      true ->
        case Config.workspace_hooks()[:before_remove] do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.workspace_hooks()[:timeout_ms]

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp source_repo_checkout_plan(repos) when is_list(repos) do
    normalized_repos =
      repos
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case normalized_repos do
      [] ->
        []

      [single_repo] ->
        [%{repo: single_repo, destination: "."}]

      [primary_repo | additional_repos] ->
        additional_plan =
          additional_repos
          |> Enum.reduce({[], MapSet.new()}, fn repo, {acc, used_names} ->
            base_name = source_repo_checkout_name(repo)
            destination = unique_checkout_destination(base_name, used_names)
            next_used_names = MapSet.put(used_names, destination)
            {acc ++ [%{repo: repo, destination: destination}], next_used_names}
          end)
          |> elem(0)

        [%{repo: primary_repo, destination: "."} | additional_plan]
    end
  end

  defp source_repo_checkout_plan(_repos), do: []

  defp source_repo_checkout_name(repo) when is_binary(repo) do
    base_name =
      repo
      |> String.trim()
      |> String.replace(~r/[\/]+$/, "")
      |> Path.basename()
      |> String.replace_suffix(".git", "")
      |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")

    normalized_base = String.downcase(base_name)

    cond do
      String.contains?(normalized_base, "frontend") -> "frontend"
      String.contains?(normalized_base, "backend-api") -> "backend-api"
      String.contains?(normalized_base, "backend") -> "backend-api"
      base_name == "" -> "repo"
      true -> base_name
    end
  end

  defp source_repo_checkout_name(_repo), do: "repo"

  defp unique_checkout_destination(base_name, used_names) do
    if MapSet.member?(used_names, base_name) do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn index ->
        candidate = "#{base_name}-#{index}"
        if MapSet.member?(used_names, candidate), do: nil, else: candidate
      end)
    else
      base_name
    end
  end

  defp run_source_repo_clone(repo, workspace, issue_context, destination) when is_binary(repo) and is_binary(destination) do
    timeout_ms = Config.workspace_hooks()[:timeout_ms]

    Logger.info("Bootstrapping workspace from source repo #{issue_log_context(issue_context)} workspace=#{workspace} repo=#{repo} destination=#{destination}")

    task =
      Task.async(fn ->
        System.cmd("git", ["clone", "--depth", "1", repo, destination], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        sanitized_output = sanitize_hook_output_for_log(output)

        Logger.warning(
          "Workspace source repo bootstrap failed #{issue_log_context(issue_context)} workspace=#{workspace} repo=#{repo} destination=#{destination} status=#{status} output=#{inspect(sanitized_output)}"
        )

        {:error, {:workspace_source_repo_clone_failed, status, output}}

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace source repo bootstrap timed out #{issue_log_context(issue_context)} workspace=#{workspace} repo=#{repo} destination=#{destination} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_source_repo_timeout, timeout_ms}}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())
    root_prefix = root <> "/"

    cond do
      expanded_workspace == root ->
        {:error, {:workspace_equals_root, expanded_workspace, root}}

      String.starts_with?(expanded_workspace <> "/", root_prefix) ->
        ensure_no_symlink_components(expanded_workspace, root)

      true ->
        {:error, {:workspace_outside_root, expanded_workspace, root}}
    end
  end

  defp ensure_no_symlink_components(workspace, root) do
    workspace
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current_path ->
      next_path = Path.join(current_path, segment)

      case File.lstat(next_path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:workspace_symlink_escape, next_path, root}}}

        {:ok, _stat} ->
          {:cont, next_path}

        {:error, :enoent} ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, {:workspace_path_unreadable, next_path, reason}}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _reason} = error -> error
      _final_path -> :ok
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      labels: extract_issue_labels(issue)
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      labels: []
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      labels: []
    }
  end

  defp extract_issue_labels(%{labels: labels}) when is_list(labels), do: normalize_labels(labels)
  defp extract_issue_labels(%{"labels" => labels}) when is_list(labels), do: normalize_labels(labels)
  defp extract_issue_labels(_issue), do: []

  defp normalize_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      label when is_binary(label) -> label
      label when is_atom(label) -> Atom.to_string(label)
      _other -> ""
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
