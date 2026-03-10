defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Linear.Client

  @linear_graphql_tool "linear_graphql"
  @human_review_state "human review"
  @human_review_gate_issue_query """
  query SymphonyHumanReviewGateIssue($issueId: String!) {
    issue(id: $issueId) {
      id
      identifier
      branchName
      team {
        states(first: 250) {
          nodes {
            id
            name
          }
        }
      }
    }
  }
  """
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    command_runner = Keyword.get(opts, :command_runner, &run_command/3)
    command_cwd = Keyword.get(opts, :command_cwd, File.cwd!())

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         :ok <- enforce_human_review_gate(query, variables, linear_client, command_runner, command_cwd),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp enforce_human_review_gate(query, variables, linear_client, command_runner, command_cwd)
       when is_binary(query) and is_map(variables) do
    case extract_state_transition(query, variables) do
      :not_issue_state_update ->
        :ok

      {:error, reason} ->
        {:error, reason}

      {:ok, %{issue_id: issue_id, state_id: state_id}} ->
        with {:ok, issue_context} <- fetch_issue_context(issue_id, state_id, linear_client),
             :ok <- enforce_human_review_pr_gate(issue_context, command_runner, command_cwd) do
          :ok
        end
    end
  end

  defp extract_state_transition(query, variables) do
    if issue_update_mutation?(query) do
      if state_id_update?(query, variables) do
        issue_id = extract_issue_id(query, variables)
        state_id = extract_state_id(query, variables)

        cond do
          not is_binary(issue_id) or String.trim(issue_id) == "" ->
            gate_error("Cannot verify Human Review gate because the state transition mutation does not include an issue ID.")

          not is_binary(state_id) or String.trim(state_id) == "" ->
            gate_error("Cannot verify Human Review gate because the state transition mutation does not include a state ID.")

          true ->
            {:ok, %{issue_id: issue_id, state_id: state_id}}
        end
      else
        :not_issue_state_update
      end
    else
      :not_issue_state_update
    end
  end

  defp issue_update_mutation?(query) when is_binary(query) do
    Regex.match?(~r/\bissueUpdate\s*\(/i, query)
  end

  defp state_id_update?(query, variables) when is_binary(query) and is_map(variables) do
    Regex.match?(~r/\bstateId\b/i, query) or map_value(variables, "stateId") != nil
  end

  defp extract_issue_id(query, variables) when is_binary(query) and is_map(variables) do
    variable_from_query(query, ~r/\bissueUpdate\s*\([^)]*\bid\s*:\s*\$(\w+)/i, variables) ||
      quoted_capture(query, ~r/\bissueUpdate\s*\([^)]*\bid\s*:\s*"([^"]+)"/i) ||
      map_value(variables, "issueId") ||
      map_value(variables, "issue_id") ||
      map_value(variables, "id")
  end

  defp extract_state_id(query, variables) when is_binary(query) and is_map(variables) do
    variable_from_query(query, ~r/\bstateId\s*:\s*\$(\w+)/i, variables) ||
      quoted_capture(query, ~r/\bstateId\s*:\s*"([^"]+)"/i) ||
      map_value(variables, "stateId") ||
      map_value(variables, "state_id")
  end

  defp variable_from_query(query, regex, variables) when is_binary(query) and is_map(variables) do
    case Regex.run(regex, query, capture: :all_but_first) do
      [name] -> map_value(variables, name)
      _ -> nil
    end
  end

  defp quoted_capture(query, regex) when is_binary(query) do
    case Regex.run(regex, query, capture: :all_but_first) do
      [value] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Enum.find_value(map, fn
      {map_key, value} when is_binary(value) ->
        if to_string(map_key) == key do
          case String.trim(value) do
            "" -> nil
            trimmed -> trimmed
          end
        else
          nil
        end

      _ ->
        nil
    end)
  end

  defp fetch_issue_context(issue_id, state_id, linear_client) do
    with {:ok, response} <- linear_client.(@human_review_gate_issue_query, %{issueId: issue_id}, []),
         {:ok, issue} <- decode_issue_response(response, issue_id),
         {:ok, state_name} <- resolve_state_name(issue, state_id) do
      {:ok,
       %{
         issue_id: issue_id,
         identifier: map_path(issue, ["identifier"]),
         branch_name: map_path(issue, ["branchName"]),
         state_name: state_name
       }}
    else
      {:error, {:human_review_gate_failed, _message, _details} = reason} ->
        {:error, reason}

      {:error, reason} ->
        gate_error("Unable to inspect issue state for Human Review gate.", %{reason: inspect(reason)})
    end
  end

  defp decode_issue_response(response, issue_id) when is_map(response) and is_binary(issue_id) do
    issue = map_path(response, ["data", "issue"])

    if is_map(issue) do
      {:ok, issue}
    else
      gate_error("Unable to inspect issue for Human Review gate.", %{issue_id: issue_id})
    end
  end

  defp resolve_state_name(issue, state_id) when is_map(issue) and is_binary(state_id) do
    states = map_path(issue, ["team", "states", "nodes"]) || []

    state_name =
      Enum.find_value(states, fn state ->
        if map_path(state, ["id"]) == state_id do
          map_path(state, ["name"])
        else
          nil
        end
      end)

    if is_binary(state_name) and String.trim(state_name) != "" do
      {:ok, state_name}
    else
      gate_error("Unable to resolve target state for Human Review gate.", %{state_id: state_id})
    end
  end

  defp enforce_human_review_pr_gate(issue_context, command_runner, command_cwd) do
    if human_review_target_state?(issue_context) do
      do_enforce_human_review_pr_gate(issue_context, command_runner, command_cwd)
    else
      :ok
    end
  end

  defp human_review_target_state?(%{state_name: state_name}) when is_binary(state_name) do
    normalize_state_name(state_name) == @human_review_state
  end

  defp human_review_target_state?(_issue_context), do: false

  defp do_enforce_human_review_pr_gate(issue_context, command_runner, command_cwd) do
    branch_name = issue_context[:branch_name]

    if is_binary(branch_name) and String.trim(branch_name) != "" do
      with :ok <- ensure_gh_auth(command_runner, command_cwd),
           {:ok, pr} <- fetch_open_pr(branch_name, command_runner, command_cwd),
           {:ok, pr_details} <- fetch_pr_details(pr, command_runner, command_cwd),
           :ok <- ensure_pr_open(pr_details),
           :ok <- ensure_checks_green(pr_details),
           :ok <- ensure_no_outstanding_change_requests(pr_details),
           :ok <- ensure_no_bot_feedback_after_head(pr_details, pr, command_runner, command_cwd) do
        :ok
      end
    else
      gate_error(
        "Cannot move to Human Review because the Linear issue has no branch name. Create and push a branch, then open a PR first.",
        %{issue_id: issue_context[:issue_id], identifier: issue_context[:identifier]}
      )
    end
  end

  defp ensure_gh_auth(command_runner, command_cwd) do
    case command_runner.("gh", ["auth", "status"], cd: command_cwd) do
      {:ok, _} ->
        :ok

      {:error, {{:enoent, _}, _output}} ->
        gate_error("Cannot verify Human Review gate because GitHub CLI is not installed.")

      {:error, {:enoent, _output}} ->
        gate_error("Cannot verify Human Review gate because GitHub CLI is not installed.")

      {:error, {status, output}} ->
        gate_error("Cannot verify Human Review gate because GitHub CLI is not authenticated.",
          status: status,
          output: trim_output(output)
        )

      {:error, reason} ->
        gate_error("Cannot verify Human Review gate because GitHub authentication check failed.",
          reason: inspect(reason)
        )
    end
  end

  defp fetch_open_pr(branch_name, command_runner, command_cwd) do
    with {:ok, output} <-
           command_runner.(
             "gh",
             ["pr", "list", "--head", branch_name, "--state", "open", "--json", "number,url,headRefName"],
             cd: command_cwd
           ),
         {:ok, prs} <- decode_json_list(output) do
      case prs do
        [pr] when is_map(pr) ->
          {:ok, pr}

        [] ->
          gate_error("Cannot move to Human Review without an open PR for the issue branch.",
            branch: branch_name
          )

        many when is_list(many) ->
          gate_error("Found multiple open PRs for the issue branch; Human Review gate requires exactly one.",
            branch: branch_name,
            count: length(many)
          )
      end
    else
      {:error, {:human_review_gate_failed, _message, _details} = reason} ->
        {:error, reason}

      {:error, {status, output}} ->
        gate_error("Failed to list open pull requests for Human Review gate.",
          status: status,
          output: trim_output(output)
        )

      {:error, reason} ->
        gate_error("Failed to list open pull requests for Human Review gate.", reason: inspect(reason))
    end
  end

  defp fetch_pr_details(pr, command_runner, command_cwd) do
    pr_number =
      case map_path(pr, ["number"]) do
        number when is_integer(number) -> Integer.to_string(number)
        number when is_binary(number) -> number
        _ -> nil
      end

    if is_binary(pr_number) and pr_number != "" do
      with {:ok, output} <-
             command_runner.(
               "gh",
               [
                 "pr",
                 "view",
                 pr_number,
                 "--json",
                 "number,url,state,headRepository,comments,reviews,commits,statusCheckRollup"
               ],
               cd: command_cwd
             ),
           {:ok, details} <- decode_json_map(output) do
        {:ok, details}
      else
        {:error, {:human_review_gate_failed, _message, _details} = reason} ->
          {:error, reason}

        {:error, {status, output}} ->
          gate_error("Failed to inspect PR details for Human Review gate.",
            status: status,
            output: trim_output(output)
          )

        {:error, reason} ->
          gate_error("Failed to inspect PR details for Human Review gate.", reason: inspect(reason))
      end
    else
      gate_error("Unable to inspect PR details for Human Review gate because PR number is missing.")
    end
  end

  defp ensure_pr_open(pr_details) do
    state = map_path(pr_details, ["state"]) |> normalize_pr_state()

    if state == "OPEN" do
      :ok
    else
      gate_error("Cannot move to Human Review because the matching PR is not open.", state: state)
    end
  end

  defp ensure_checks_green(pr_details) do
    rollup = map_path(pr_details, ["statusCheckRollup"])
    checks = if is_list(rollup), do: rollup, else: []

    pending_count = Enum.count(checks, &check_pending?/1)
    failing_count = Enum.count(checks, &check_failed?/1)

    cond do
      pending_count > 0 ->
        gate_error("Cannot move to Human Review while PR checks are still pending.",
          pending_checks: pending_count
        )

      failing_count > 0 ->
        gate_error("Cannot move to Human Review because PR checks are failing.",
          failing_checks: failing_count
        )

      true ->
        :ok
    end
  end

  defp check_pending?(check) when is_map(check) do
    status =
      map_path(check, ["status"]) ||
        map_path(check, ["state"]) ||
        ""

    normalized_status =
      status
      |> to_string()
      |> String.trim()
      |> String.upcase()

    conclusion =
      map_path(check, ["conclusion"])
      |> to_string()
      |> String.trim()
      |> String.upcase()

    normalized_status in ["QUEUED", "IN_PROGRESS", "PENDING", "REQUESTED", "WAITING"] or
      (normalized_status == "COMPLETED" and conclusion == "")
  end

  defp check_pending?(_check), do: false

  defp check_failed?(check) when is_map(check) do
    state =
      map_path(check, ["state"])
      |> to_string()
      |> String.trim()
      |> String.upcase()

    conclusion =
      map_path(check, ["conclusion"])
      |> to_string()
      |> String.trim()
      |> String.upcase()

    state in ["FAILURE", "ERROR"] or
      conclusion in ["FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED", "STALE"]
  end

  defp check_failed?(_check), do: false

  defp ensure_no_outstanding_change_requests(pr_details) do
    reviews = map_path(pr_details, ["reviews"])
    latest_reviews = latest_reviews_by_author(reviews)

    requesting_changes =
      latest_reviews
      |> Enum.filter(fn {_author, review} ->
        normalize_review_state(review[:state]) == "CHANGES_REQUESTED"
      end)
      |> Enum.map(fn {author, _review} -> author end)

    if requesting_changes == [] do
      :ok
    else
      gate_error("Cannot move to Human Review while a PR review still requests changes.",
        reviewers: requesting_changes
      )
    end
  end

  defp latest_reviews_by_author(reviews) when is_list(reviews) do
    Enum.reduce(reviews, %{}, fn review, acc ->
      author = review_author(review)
      state = normalize_review_state(map_path(review, ["state"]))
      submitted_at = parse_datetime(map_path(review, ["submittedAt"]))

      if author != nil and state != nil and submitted_at != nil do
        case Map.get(acc, author) do
          nil ->
            Map.put(acc, author, %{state: state, submitted_at: submitted_at})

          existing ->
            if DateTime.compare(submitted_at, existing.submitted_at) == :gt do
              Map.put(acc, author, %{state: state, submitted_at: submitted_at})
            else
              acc
            end
        end
      else
        acc
      end
    end)
  end

  defp latest_reviews_by_author(_reviews), do: %{}

  defp ensure_no_bot_feedback_after_head(pr_details, pr, command_runner, command_cwd) do
    with {:ok, head_commit_at} <- latest_commit_at(pr_details),
         {:ok, inline_comments} <- fetch_inline_review_comments(pr_details, pr, command_runner, command_cwd) do
      top_level_comments = map_path(pr_details, ["comments"]) || []
      reviews = map_path(pr_details, ["reviews"]) || []

      bot_feedback_count =
        count_bot_comments_after(top_level_comments, head_commit_at) +
          count_bot_reviews_after(reviews, head_commit_at) +
          count_inline_bot_comments_after(inline_comments, head_commit_at)

      if bot_feedback_count == 0 do
        :ok
      else
        gate_error(
          "Cannot move to Human Review because bot review feedback exists after the latest PR commit. Address it and push updates first.",
          bot_feedback_items: bot_feedback_count
        )
      end
    end
  end

  defp latest_commit_at(pr_details) do
    commits = map_path(pr_details, ["commits"]) || []

    latest =
      commits
      |> Enum.map(fn commit ->
        parse_datetime(map_path(commit, ["committedDate"])) ||
          parse_datetime(map_path(commit, ["commit", "committedDate"]))
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort(&(DateTime.compare(&1, &2) == :gt))
      |> List.first()

    if is_struct(latest, DateTime) do
      {:ok, latest}
    else
      gate_error("Cannot verify Human Review gate because PR commit history is unavailable.")
    end
  end

  defp fetch_inline_review_comments(pr_details, pr, command_runner, command_cwd) do
    repo = map_path(pr_details, ["headRepository", "nameWithOwner"])
    pr_number = map_path(pr, ["number"])

    cond do
      not is_binary(repo) or String.trim(repo) == "" ->
        gate_error("Cannot verify inline PR review comments because repository metadata is missing.")

      is_nil(pr_number) ->
        gate_error("Cannot verify inline PR review comments because PR number is missing.")

      true ->
        with {:ok, output} <-
               command_runner.(
                 "gh",
                 [
                   "api",
                   "repos/#{repo}/pulls/#{pr_number}/comments?per_page=100"
                 ],
                 cd: command_cwd
               ),
             {:ok, comments} <- decode_json_list(output) do
          {:ok, comments}
        else
          {:error, {:human_review_gate_failed, _message, _details} = reason} ->
            {:error, reason}

          {:error, {status, output}} ->
            gate_error("Failed to read inline PR review comments for Human Review gate.",
              status: status,
              output: trim_output(output)
            )

          {:error, reason} ->
            gate_error("Failed to read inline PR review comments for Human Review gate.",
              reason: inspect(reason)
            )
        end
    end
  end

  defp count_bot_comments_after(comments, head_commit_at) when is_list(comments) do
    Enum.count(comments, fn comment ->
      bot_author?(map_path(comment, ["author"])) and
        datetime_after?(map_path(comment, ["createdAt"]), head_commit_at)
    end)
  end

  defp count_bot_comments_after(_comments, _head_commit_at), do: 0

  defp count_bot_reviews_after(reviews, head_commit_at) when is_list(reviews) do
    Enum.count(reviews, fn review ->
      bot_author?(map_path(review, ["author"])) and
        review_actionable?(review) and
        datetime_after?(map_path(review, ["submittedAt"]), head_commit_at)
    end)
  end

  defp count_bot_reviews_after(_reviews, _head_commit_at), do: 0

  defp count_inline_bot_comments_after(comments, head_commit_at) when is_list(comments) do
    Enum.count(comments, fn comment ->
      bot_author?(map_path(comment, ["user"])) and
        datetime_after?(map_path(comment, ["created_at"]), head_commit_at)
    end)
  end

  defp count_inline_bot_comments_after(_comments, _head_commit_at), do: 0

  defp review_actionable?(review) when is_map(review) do
    normalize_review_state(map_path(review, ["state"])) in ["COMMENTED", "CHANGES_REQUESTED"]
  end

  defp review_actionable?(_review), do: false

  defp review_author(review) when is_map(review) do
    author = map_path(review, ["author"])
    login = map_path(author, ["login"])

    case login do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp review_author(_review), do: nil

  defp bot_author?(author) when is_map(author) do
    login = map_path(author, ["login"])
    is_bot = map_path(author, ["isBot"]) || map_path(author, ["is_bot"])

    is_bot == true or bot_login?(login)
  end

  defp bot_author?(_author), do: false

  defp bot_login?(login) when is_binary(login) do
    normalized = String.downcase(String.trim(login))

    normalized != "" and
      (String.ends_with?(normalized, "[bot]") or String.ends_with?(normalized, "bot"))
  end

  defp bot_login?(_login), do: false

  defp datetime_after?(value, %DateTime{} = head_commit_at) do
    case parse_datetime(value) do
      %DateTime{} = datetime -> DateTime.compare(datetime, head_commit_at) == :gt
      _ -> false
    end
  end

  defp datetime_after?(_value, _head_commit_at), do: false

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_pr_state(state) when is_binary(state), do: String.upcase(String.trim(state))
  defp normalize_pr_state(_state), do: nil

  defp normalize_review_state(state) when is_binary(state) do
    normalized = String.upcase(String.trim(state))
    if normalized == "", do: nil, else: normalized
  end

  defp normalize_review_state(_state), do: nil

  defp normalize_state_name(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state_name(_state_name), do: ""

  defp map_path(map, [segment | rest]) when is_map(map) and is_binary(segment) do
    Enum.find_value(map, fn
      {key, value} ->
        if to_string(key) == segment do
          if rest == [] do
            value
          else
            map_path(value, rest)
          end
        else
          nil
        end
    end)
  end

  defp map_path(value, []), do: value
  defp map_path(_value, _path), do: nil

  defp decode_json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> gate_error("Received invalid JSON object while enforcing Human Review gate.")
      {:error, reason} -> gate_error("Received malformed JSON while enforcing Human Review gate.", error: inspect(reason))
    end
  end

  defp decode_json_map(value) when is_map(value), do: {:ok, value}

  defp decode_json_map(_value),
    do: gate_error("Received invalid JSON response while enforcing Human Review gate.")

  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
      {:ok, _other} -> gate_error("Received invalid JSON list while enforcing Human Review gate.")
      {:error, reason} -> gate_error("Received malformed JSON while enforcing Human Review gate.", error: inspect(reason))
    end
  end

  defp decode_json_list(value) when is_list(value), do: {:ok, value}

  defp decode_json_list(_value),
    do: gate_error("Received invalid JSON list response while enforcing Human Review gate.")

  defp run_command(command, args, opts) when is_binary(command) and is_list(args) and is_list(opts) do
    with executable when is_binary(executable) <- System.find_executable(command) do
      cmd_opts =
        case Keyword.get(opts, :cd) do
          cd when is_binary(cd) and cd != "" -> [stderr_to_stdout: true, cd: cd]
          _ -> [stderr_to_stdout: true]
        end

      case System.cmd(executable, args, cmd_opts) do
        {output, 0} -> {:ok, output}
        {output, status} -> {:error, {status, output}}
      end
    else
      nil ->
        {:error, {:enoent, "#{command} executable not found"}}
    end
  end

  defp trim_output(output) when is_binary(output) do
    output
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp trim_output(_output), do: ""

  defp gate_error(message, details \\ %{})

  defp gate_error(message, details) when is_binary(message) and is_map(details) do
    {:error, {:human_review_gate_failed, message, details}}
  end

  defp gate_error(message, details) when is_binary(message) and is_list(details) do
    gate_error(message, Map.new(details))
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    case reason do
      {:human_review_gate_failed, message, details} ->
        %{
          "error" => %{
            "message" => message,
            "details" => details
          }
        }

      _ ->
        %{
          "error" => %{
            "message" => "Linear GraphQL tool execution failed.",
            "reason" => inspect(reason)
          }
        }
    end
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
