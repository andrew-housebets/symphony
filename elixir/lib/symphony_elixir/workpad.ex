defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Harness-owned Linear workpad management for fresh-context turns.
  """

  require Logger

  alias SymphonyElixir.{Linear.Comment, Linear.Issue, Tracker}

  @workpad_header "## Codex Workpad"
  @harness_handoff_heading "### Harness Handoff"

  @type state :: %{
          comment_id: String.t(),
          body: String.t()
        }

  @spec ensure(Issue.t(), Path.t()) :: {:ok, state()} | {:error, term()} | :skip
  def ensure(%Issue{id: issue_id}, workspace) when is_binary(issue_id) and is_binary(workspace) do
    with {:ok, comments} <- Tracker.fetch_issue_comments(issue_id) do
      case find_workpad_comment(comments) do
        %Comment{id: comment_id, body: body} when is_binary(comment_id) and is_binary(body) ->
          {:ok, %{comment_id: comment_id, body: body}}

        _ ->
          body = bootstrap_body(workspace)

          case Tracker.create_comment_with_id(issue_id, body) do
            {:ok, comment_id} ->
              Logger.info("Created harness workpad comment for issue_id=#{issue_id} comment_id=#{comment_id}")
              {:ok, %{comment_id: comment_id, body: body}}

            {:error, reason} ->
              {:error, {:workpad_create_failed, reason}}
          end
      end
    end
  end

  def ensure(_issue, _workspace), do: :skip

  @spec handoff_excerpt(state() | :skip) :: String.t()
  def handoff_excerpt(:skip), do: "No harness handoff available."

  def handoff_excerpt(%{body: body}) when is_binary(body) do
    case Regex.run(~r/#{Regex.escape(@harness_handoff_heading)}\n\n(.*?)(?=\n### |\z)/ms, body, capture: :all_but_first) do
      [content] -> String.trim(content)
      _ -> "No harness handoff available."
    end
  end

  @spec without_harness_handoff(String.t() | nil) :: String.t()
  def without_harness_handoff(body) when is_binary(body) do
    Regex.replace(~r/\n?#{Regex.escape(@harness_handoff_heading)}\n\n.*?(?=\n### |\z)/ms, body, "")
    |> String.trim()
  end

  def without_harness_handoff(_body), do: ""

  @spec record_turn_handoff(state() | :skip, Issue.t(), Path.t(), pos_integer(), pos_integer(), map()) ::
          {:ok, state()} | {:error, term()} | :skip
  def record_turn_handoff(:skip, _issue, _workspace, _turn_number, _max_turns, _snapshot), do: :skip

  def record_turn_handoff(%{comment_id: comment_id, body: body} = _workpad, issue, workspace, turn_number, max_turns, snapshot)
      when is_binary(comment_id) and is_binary(body) do
    updated_body =
      body
      |> ensure_sections(workspace)
      |> upsert_section(@harness_handoff_heading, handoff_body(issue, workspace, turn_number, max_turns, snapshot))

    case Tracker.update_comment(comment_id, updated_body) do
      :ok ->
        {:ok, %{comment_id: comment_id, body: updated_body}}

      {:error, reason} ->
        {:error, {:workpad_update_failed, reason}}
    end
  end

  defp find_workpad_comment(comments) when is_list(comments) do
    Enum.find(comments, fn
      %Comment{body: body, resolved_at: nil} when is_binary(body) ->
        String.contains?(body, @workpad_header)

      _ ->
        false
    end)
  end

  defp bootstrap_body(workspace) do
    stamp = environment_stamp(workspace)

    """
    #{@workpad_header}

    ```text
    #{stamp}
    ```

    ### Plan

    - [ ] Reconcile current task state
    - [ ] Complete remaining ticket work

    ### Acceptance Criteria

    - [ ] Confirm the issue requirements are satisfied

    ### Validation

    - [ ] Record verification commands and outcomes

    ### Notes

    - Harness bootstrapped the workpad for fresh-context continuation turns.

    #{@harness_handoff_heading}

    - Pending first turn handoff.
    """
    |> String.trim()
  end

  defp ensure_sections(body, workspace) when is_binary(body) do
    body
    |> ensure_header_and_stamp(workspace)
    |> ensure_section("### Plan", "- [ ] Reconcile current task state\n- [ ] Complete remaining ticket work")
    |> ensure_section("### Acceptance Criteria", "- [ ] Confirm the issue requirements are satisfied")
    |> ensure_section("### Validation", "- [ ] Record verification commands and outcomes")
    |> ensure_section("### Notes", "- Harness is maintaining this workpad for fresh-context continuation turns.")
  end

  defp ensure_header_and_stamp(body, workspace) do
    stamp = environment_stamp(workspace)

    cond do
      String.contains?(body, @workpad_header) and Regex.match?(~r/```text\n.*?\n```/s, body) ->
        Regex.replace(~r/```text\n.*?\n```/s, body, "```text\n#{stamp}\n```", global: false)

      String.contains?(body, @workpad_header) ->
        String.replace(body, @workpad_header, @workpad_header <> "\n\n```text\n" <> stamp <> "\n```", global: false)

      true ->
        bootstrap_body(workspace) <> "\n\n" <> String.trim(body)
    end
  end

  defp ensure_section(body, heading, default_content) do
    if String.contains?(body, heading) do
      body
    else
      String.trim_trailing(body) <> "\n\n" <> heading <> "\n\n" <> default_content
    end
  end

  defp upsert_section(body, heading, content) do
    replacement = heading <> "\n\n" <> content

    if String.contains?(body, heading) do
      Regex.replace(~r/#{Regex.escape(heading)}\n\n.*?(?=\n### |\z)/ms, body, replacement)
    else
      String.trim_trailing(body) <> "\n\n" <> replacement
    end
  end

  defp handoff_body(issue, workspace, turn_number, max_turns, snapshot) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    branch = Map.get(snapshot, :branch, "unknown")
    head = Map.get(snapshot, :head, "unknown")
    changed_files = Map.get(snapshot, :changed_files, [])
    last_event = Map.get(snapshot, :last_event, "unknown")
    last_summary = Map.get(snapshot, :last_summary, "n/a")
    total_tokens = get_in(snapshot, [:usage, :total_tokens]) || 0
    no_progress = Map.get(snapshot, :no_progress?, false)

    changed_file_lines =
      case changed_files do
        [] -> ["- Working tree: clean"]
        files -> ["- Working tree changes:"] ++ Enum.map(files, &("  - " <> &1))
      end

    [
      "- Updated at: `#{timestamp}`",
      "- Issue: `#{issue.identifier}`",
      "- Turn: `#{turn_number}` of `#{max_turns}`",
      "- Workspace: `#{Path.expand(workspace)}`",
      "- Git: branch `#{branch}`, HEAD `#{head}`",
      "- Last Codex signal: `#{last_event}`",
      "- Last Codex summary: #{last_summary}",
      "- Token usage so far this run: `#{total_tokens}`",
      "- No-progress gate: `#{if(no_progress, do: "tripped", else: "clear")}`"
      | changed_file_lines
    ]
    |> Enum.join("\n")
  end

  defp environment_stamp(workspace) do
    host =
      case :inet.gethostname() do
        {:ok, hostname} -> to_string(hostname)
        _ -> "unknown-host"
      end

    head =
      case System.cmd("git", ["-C", workspace, "rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
        {sha, 0} -> sha |> String.trim()
        _ -> "unknown"
      end

    "#{host}:#{Path.expand(workspace)}@#{head}"
  end
end
