defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace, Workpad}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    Logger.info("Starting agent run for #{issue_context(issue)}")

    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue),
               :ok <- run_codex_turns(workspace, issue, codex_update_recipient, opts) do
            :ok
          else
            {:error, reason} ->
              Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
              raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
          end
        after
          Workspace.run_after_run_hook(workspace, issue)
        end

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp codex_message_handler(recipient, issue, usage_tracker) do
    fn message ->
      track_token_usage(usage_tracker, message)
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns())
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    {:ok, usage_tracker} =
      Agent.start_link(fn ->
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          last_event: nil,
          last_summary: nil
        }
      end)

    workpad =
      case Workpad.ensure(issue, workspace) do
        {:ok, state} ->
          state

        :skip ->
          :skip

        {:error, reason} ->
          Logger.warning("Failed to initialize workpad for #{issue_context(issue)}: #{inspect(reason)}")
          :skip
      end

    update_usage_tracker_workpad(usage_tracker, workpad)

    try do
      do_run_codex_turns(
        workspace,
        issue,
        codex_update_recipient,
        usage_tracker,
        workpad,
        opts,
        issue_state_fetcher,
        1,
        max_turns
      )
    after
      if Process.alive?(usage_tracker), do: Agent.stop(usage_tracker)
    end
  end

  defp maybe_start_recipient_watcher(_session, recipient, _issue) when not is_pid(recipient), do: nil

  defp maybe_start_recipient_watcher(_session, recipient, issue) do
    owner = self()
    spawn(fn -> watch_recipient_lifecycle(recipient, owner, issue) end)
  end

  defp stop_recipient_watcher(nil), do: :ok
  defp stop_recipient_watcher(pid) when is_pid(pid), do: send(pid, :stop)

  defp watch_recipient_lifecycle(recipient, owner, issue) when is_pid(recipient) and is_pid(owner) do
    recipient_ref = Process.monitor(recipient)
    owner_ref = Process.monitor(owner)

    receive do
      {:DOWN, ^recipient_ref, :process, _pid, reason} ->
        Logger.warning("Codex update recipient exited for #{issue_context(issue)} reason=#{inspect(reason)}; cancelling codex turn")

        send(owner, {:symphony_cancel_turn, {:codex_update_recipient_down, reason}})
        Process.demonitor(owner_ref, [:flush])

      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        Process.demonitor(recipient_ref, [:flush])

      :stop ->
        Process.demonitor(recipient_ref, [:flush])
        Process.demonitor(owner_ref, [:flush])
        :ok
    end
  end

  defp do_run_codex_turns(
         workspace,
         issue,
         codex_update_recipient,
         usage_tracker,
         workpad,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    workspace_before = current_workspace_snapshot(workspace)
    workpad_before = refresh_workpad(workpad, issue, workspace)
    prompt = build_turn_prompt(issue, usage_tracker, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           run_codex_turn(workspace, prompt, issue, codex_update_recipient, usage_tracker) do
      usage = current_token_usage(usage_tracker)
      workspace_after = current_workspace_snapshot(workspace)
      latest_workpad = refresh_workpad(workpad_before, issue, workspace)
      no_progress? = no_progress?(workspace_before, workspace_after, workpad_before, latest_workpad)

      workpad =
        case update_workpad_handoff(latest_workpad, issue, workspace, turn_number, max_turns, usage, no_progress?) do
          {:ok, updated_workpad} ->
            updated_workpad

          :skip ->
            latest_workpad

          {:error, reason} ->
            Logger.warning("Failed to update workpad handoff for #{issue_context(issue)}: #{inspect(reason)}")
            latest_workpad
        end

      update_usage_tracker_workpad(usage_tracker, workpad)

      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when no_progress? and turn_number > 1 ->
          handle_no_progress(refreshed_issue)
          :ok

        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            workspace,
            refreshed_issue,
            codex_update_recipient,
            usage_tracker,
            workpad,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, _usage_tracker, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, usage_tracker, _opts, turn_number, max_turns) do
    usage = current_token_usage(usage_tracker)
    workpad = current_workpad_state(usage_tracker)
    workpad_comment_id = workpad_comment_id(workpad)

    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Start this turn in a fresh Codex context and treat the current workspace and Linear workpad as the source of truth.
    - Re-read the repository state and the `### Harness Handoff` section of the workpad instead of relying on prior chat history.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    - Workpad comment ID: `#{workpad_comment_id}`

    Current workpad handoff:
    #{Workpad.handoff_excerpt(workpad)}

    #{PromptBuilder.budget_guidance(run_total_tokens: usage.total_tokens, issue_window_tokens: usage.total_tokens)}
    """
  end

  defp run_codex_turn(workspace, prompt, issue, codex_update_recipient, usage_tracker) do
    with {:ok, session} <- AppServer.start_session(workspace) do
      recipient_watcher = maybe_start_recipient_watcher(session, codex_update_recipient, issue)

      try do
        AppServer.run_turn(
          session,
          prompt,
          issue,
          on_message: codex_message_handler(codex_update_recipient, issue, usage_tracker)
        )
      after
        stop_recipient_watcher(recipient_watcher)
        AppServer.stop_session(session)
      end
    end
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp current_token_usage(usage_tracker) when is_pid(usage_tracker) do
    Agent.get(usage_tracker, & &1)
  catch
    :exit, _reason -> %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end

  defp current_token_usage(_usage_tracker), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp track_token_usage(usage_tracker, message) when is_pid(usage_tracker) and is_map(message) do
    event = Map.get(message, :event) || Map.get(message, "event")
    summary = summarize_codex_message(message)

    case absolute_token_usage_from_message(message) do
      %{input_tokens: input_tokens, output_tokens: output_tokens, total_tokens: total_tokens} ->
        Agent.update(usage_tracker, fn usage ->
          %{
            input_tokens: max(Map.get(usage, :input_tokens, 0), input_tokens),
            output_tokens: max(Map.get(usage, :output_tokens, 0), output_tokens),
            total_tokens: max(Map.get(usage, :total_tokens, 0), total_tokens),
            last_event: event,
            last_summary: summary
          }
        end)

      _ ->
        Agent.update(usage_tracker, fn usage ->
          %{usage | last_event: event, last_summary: summary}
        end)
    end
  catch
    :exit, _reason -> :ok
  end

  defp track_token_usage(_usage_tracker, _message), do: :ok

  defp update_usage_tracker_workpad(usage_tracker, workpad) when is_pid(usage_tracker) do
    Agent.update(usage_tracker, &Map.put(&1, :workpad, workpad))
  catch
    :exit, _reason -> :ok
  end

  defp update_usage_tracker_workpad(_usage_tracker, _workpad), do: :ok

  defp absolute_token_usage_from_message(message) when is_map(message) do
    payload = Map.get(message, :payload) || Map.get(message, "payload")
    details = Map.get(message, :details) || Map.get(message, "details")

    [message, payload, details]
    |> Enum.find_value(&absolute_token_usage_from_payload/1)
  end

  defp absolute_token_usage_from_message(_message), do: nil

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total],
      ["usage"],
      [:usage],
      ["params", "usage"],
      [:params, :usage]
    ]

    Enum.find_value(absolute_paths, fn path ->
      case map_at_path(payload, path) do
        %{} = candidate ->
          normalize_integer_token_map(candidate)

        _ ->
          nil
      end
    end)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp map_at_path(value, []), do: value

  defp map_at_path(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, next} -> map_at_path(next, rest)
      :error -> nil
    end
  end

  defp map_at_path(_value, _path), do: nil

  defp normalize_integer_token_map(candidate) when is_map(candidate) do
    input_tokens = map_integer_value(candidate, ["input_tokens", :input_tokens, "input", :input])
    output_tokens = map_integer_value(candidate, ["output_tokens", :output_tokens, "output", :output, "completion_tokens", :completion_tokens])
    total_tokens = map_integer_value(candidate, ["total_tokens", :total_tokens, "total", :total])

    if is_integer(input_tokens) and is_integer(output_tokens) and is_integer(total_tokens) do
      %{input_tokens: input_tokens, output_tokens: output_tokens, total_tokens: total_tokens}
    end
  end

  defp normalize_integer_token_map(_candidate), do: nil

  defp map_integer_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> integer_like(value)
        :error -> nil
      end
    end)
  end

  defp map_integer_value(_map, _keys), do: nil

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, _} when number >= 0 -> number
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp update_workpad_handoff(workpad, issue, workspace, turn_number, max_turns, usage, no_progress?) do
    snapshot =
      current_workspace_snapshot(workspace)
      |> Map.put(:usage, usage)
      |> Map.put(:last_event, Map.get(usage, :last_event))
      |> Map.put(:last_summary, Map.get(usage, :last_summary))
      |> Map.put(:no_progress?, no_progress?)

    Workpad.record_turn_handoff(workpad, issue, workspace, turn_number, max_turns, snapshot)
  end

  defp current_workspace_snapshot(workspace) when is_binary(workspace) do
    %{
      branch: git_output(workspace, ["rev-parse", "--abbrev-ref", "HEAD"]),
      head: git_output(workspace, ["rev-parse", "--short", "HEAD"]),
      changed_files:
        git_output(workspace, ["status", "--short"])
        |> String.split("\n", trim: true)
        |> Enum.take(20)
    }
  end

  defp current_workspace_snapshot(_workspace), do: %{branch: "unknown", head: "unknown", changed_files: []}

  defp git_output(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  end

  defp summarize_codex_message(message) when is_map(message) do
    event = Map.get(message, :event) || Map.get(message, "event")
    payload = Map.get(message, :payload) || Map.get(message, "payload")
    method = if is_map(payload), do: Map.get(payload, "method") || Map.get(payload, :method)

    cond do
      is_binary(method) -> method
      is_atom(event) -> Atom.to_string(event)
      is_binary(event) -> event
      true -> "unknown"
    end
  end

  defp summarize_codex_message(_message), do: "unknown"

  defp refresh_workpad(:skip, _issue, _workspace), do: :skip

  defp refresh_workpad(_workpad, issue, workspace) do
    case Workpad.ensure(issue, workspace) do
      {:ok, refreshed} -> refreshed
      :skip -> :skip
      {:error, _reason} -> :skip
    end
  end

  defp no_progress?(workspace_before, workspace_after, workpad_before, workpad_after) do
    not workspace_progress?(workspace_before, workspace_after) and
      not workpad_progress?(workpad_before, workpad_after)
  end

  defp workspace_progress?(before_snapshot, after_snapshot) do
    Map.get(before_snapshot, :head) != Map.get(after_snapshot, :head) or
      Map.get(before_snapshot, :changed_files) != Map.get(after_snapshot, :changed_files)
  end

  defp workpad_progress?(%{body: before_body}, %{body: after_body}) do
    Workpad.without_harness_handoff(before_body) != Workpad.without_harness_handoff(after_body)
  end

  defp workpad_progress?(_before, _after), do: false

  defp handle_no_progress(%Issue{} = issue) do
    Logger.warning("No progress detected for #{issue_context(issue)}; pausing issue to avoid token burn")

    case List.first(Config.linear_paused_states()) do
      state_name when is_binary(state_name) and state_name != "" ->
        case Tracker.update_issue_state(issue.id, state_name) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("Failed to pause no-progress issue #{issue_context(issue)}: #{inspect(reason)}")
        end

      _ ->
        :ok
    end
  end

  defp current_workpad_state(usage_tracker) when is_pid(usage_tracker) do
    Agent.get(usage_tracker, &Map.get(&1, :workpad, :skip))
  catch
    :exit, _reason -> :skip
  end

  defp current_workpad_state(_usage_tracker), do: :skip

  defp workpad_comment_id(%{comment_id: comment_id}) when is_binary(comment_id), do: comment_id
  defp workpad_comment_id(_workpad), do: "unknown"
end
