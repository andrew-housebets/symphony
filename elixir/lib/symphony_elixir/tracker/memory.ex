defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{Comment, Issue}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec fetch_issue_comments(String.t()) :: {:ok, [Comment.t()]} | {:error, term()}
  def fetch_issue_comments(issue_id) when is_binary(issue_id) do
    comments =
      configured_comments()
      |> Map.get(issue_id, [])
      |> Enum.filter(&match?(%Comment{}, &1))

    {:ok, comments}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    send_event({:memory_tracker_comment, issue_id, body})
    :ok
  end

  @spec create_comment_with_id(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_comment_with_id(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    comment_id = "memory-comment-" <> Integer.to_string(System.unique_integer([:positive]))
    comment = %Comment{id: comment_id, body: body, updated_at: DateTime.utc_now(), resolved_at: nil}

    comments =
      configured_comments()
      |> Map.update(issue_id, [comment], &[comment | &1])

    Application.put_env(:symphony_elixir, :memory_tracker_comments, comments)
    send_event({:memory_tracker_comment_created, issue_id, comment_id, body})
    {:ok, comment_id}
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) when is_binary(comment_id) and is_binary(body) do
    comments =
      configured_comments()
      |> Enum.into(%{}, fn {issue_id, issue_comments} ->
        updated_comments =
          Enum.map(issue_comments, fn
            %Comment{id: ^comment_id} = comment ->
              %{comment | body: body, updated_at: DateTime.utc_now()}

            comment ->
              comment
          end)

        {issue_id, updated_comments}
      end)

    Application.put_env(:symphony_elixir, :memory_tracker_comments, comments)
    send_event({:memory_tracker_comment_updated, comment_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp configured_comments do
    Application.get_env(:symphony_elixir, :memory_tracker_comments, %{})
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
