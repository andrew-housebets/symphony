defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the linear_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Linear"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert [
             %{
               "text" => missing_token_text
             }
           ] = missing_token["contentItems"]

    assert Jason.decode!(missing_token_text) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert [
             %{
               "text" => status_error_text
             }
           ] = status_error["contentItems"]

    assert Jason.decode!(status_error_text) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert [
             %{
               "text" => request_error_text
             }
           ] = request_error["contentItems"]

    assert Jason.decode!(request_error_text) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql blocks Human Review transition without an open PR" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => issue_state_update_query(),
          "variables" => %{"issueId" => "issue-123", "stateId" => "state-human-review"}
        },
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:linear_client_called, query, variables})
          {:ok, human_review_gate_issue_response("Human Review")}
        end,
        command_runner: fn
          "gh", ["auth", "status"], _opts -> {:ok, "ok"}
          "gh", ["pr", "list" | _rest], _opts -> {:ok, "[]"}
          _command, _args, _opts -> flunk("unexpected command runner invocation")
        end
      )

    assert_received {:linear_client_called, query, gate_variables}
    assert query =~ "query SymphonyHumanReviewGateIssue"
    assert gate_variables == %{issueId: "issue-123"}

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert %{
             "error" => %{
               "message" => message
             }
           } = Jason.decode!(text)

    assert message =~ "without an open PR"
  end

  test "linear_graphql allows non-Human Review state transitions without GitHub checks" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => issue_state_update_query(),
          "variables" => %{"issueId" => "issue-123", "stateId" => "state-in-progress"}
        },
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:linear_client_called, query, variables})

          if query =~ "query SymphonyHumanReviewGateIssue" do
            {:ok, human_review_gate_issue_response("In Progress", "state-in-progress")}
          else
            {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
          end
        end,
        command_runner: fn _command, _args, _opts ->
          flunk("GitHub checks should not run for non-Human Review transitions")
        end
      )

    assert_received {:linear_client_called, gate_query, gate_variables}
    assert gate_query =~ "query SymphonyHumanReviewGateIssue"
    assert gate_variables == %{issueId: "issue-123"}

    assert_received {:linear_client_called, mutation_query, mutation_variables}
    assert mutation_query =~ "mutation MoveIssue"
    assert mutation_variables == %{"issueId" => "issue-123", "stateId" => "state-in-progress"}
    assert response["success"] == true
  end

  test "linear_graphql blocks In Progress transition when branch name is missing" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => issue_state_update_query(),
          "variables" => %{"issueId" => "issue-123", "stateId" => "state-in-progress"}
        },
        linear_client: fn query, _variables, _opts ->
          if query =~ "query SymphonyHumanReviewGateIssue" do
            {:ok, human_review_gate_issue_response("In Progress", "state-in-progress", nil)}
          else
            flunk("mutation should not run when branch name is missing")
          end
        end,
        command_runner: fn _command, _args, _opts ->
          flunk("GitHub checks should not run when branch policy gate fails")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert %{
             "error" => %{
               "message" => message
             }
           } = Jason.decode!(text)

    assert message =~ "branch name is required"
  end

  test "linear_graphql blocks In Progress transition when branch name is not conventional" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => issue_state_update_query(),
          "variables" => %{"issueId" => "issue-123", "stateId" => "state-in-progress"}
        },
        linear_client: fn query, _variables, _opts ->
          if query =~ "query SymphonyHumanReviewGateIssue" do
            {:ok, human_review_gate_issue_response("In Progress", "state-in-progress", "andrew/issue-123")}
          else
            flunk("mutation should not run when branch name is invalid")
          end
        end,
        command_runner: fn _command, _args, _opts ->
          flunk("GitHub checks should not run when branch policy gate fails")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert %{
             "error" => %{
               "message" => message
             }
           } = Jason.decode!(text)

    assert message =~ "does not follow conventional format"
  end

  test "linear_graphql allows In Progress transition when branch name is supplied in the mutation" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => issue_state_and_branch_update_query(),
          "variables" => %{
            "issueId" => "issue-123",
            "stateId" => "state-in-progress",
            "branchName" => "fix/issue-123"
          }
        },
        linear_client: fn query, variables, _opts ->
          if query =~ "query SymphonyHumanReviewGateIssue" do
            {:ok, human_review_gate_issue_response("In Progress", "state-in-progress", nil)}
          else
            assert query =~ "mutation MoveIssueBranch"
            assert variables["branchName"] == "fix/issue-123"
            {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
          end
        end,
        command_runner: fn _command, _args, _opts ->
          flunk("GitHub checks should not run for non-Human Review transitions")
        end
      )

    assert response["success"] == true
  end

  test "linear_graphql accepts all supported conventional branch prefixes for active states" do
    prefixes = ~w(build chore ci docs feat fix perf refactor revert style test)

    for prefix <- prefixes do
      branch_name = "#{prefix}/issue-123"

      response =
        DynamicTool.execute(
          "linear_graphql",
          %{
            "query" => issue_state_and_branch_update_query(),
            "variables" => %{
              "issueId" => "issue-123",
              "stateId" => "state-in-progress",
              "branchName" => branch_name
            }
          },
          linear_client: fn query, variables, _opts ->
            if query =~ "query SymphonyHumanReviewGateIssue" do
              {:ok, human_review_gate_issue_response("In Progress", "state-in-progress", nil)}
            else
              assert query =~ "mutation MoveIssueBranch"
              assert variables["branchName"] == branch_name
              {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
            end
          end,
          command_runner: fn _command, _args, _opts ->
            flunk("GitHub checks should not run for non-Human Review transitions")
          end
        )

      assert response["success"] == true
    end
  end

  test "linear_graphql blocks Human Review transition when checks are still pending" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => issue_state_update_query(),
          "variables" => %{"issueId" => "issue-123", "stateId" => "state-human-review"}
        },
        linear_client: fn query, _variables, _opts ->
          if query =~ "query SymphonyHumanReviewGateIssue" do
            {:ok, human_review_gate_issue_response("Human Review")}
          else
            flunk("mutation should not run when checks are pending")
          end
        end,
        command_runner: fn
          "gh", ["auth", "status"], _opts ->
            {:ok, "ok"}

          "gh", ["pr", "list" | _rest], _opts ->
            {:ok, ~s([{"number":42,"url":"https://github.com/example/repo/pull/42","headRefName":"feat/issue-123"}])}

          "gh", ["pr", "view", "42" | _rest], _opts ->
            {:ok,
             ~s({"number":42,"url":"https://github.com/example/repo/pull/42","state":"OPEN","headRepository":{"nameWithOwner":"example/repo"},"comments":[],"reviews":[],"commits":[{"committedDate":"2026-03-10T10:00:00Z"}],"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":null}]})}

          _command, _args, _opts ->
            flunk("unexpected command runner invocation")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert %{
             "error" => %{
               "message" => message
             }
           } = Jason.decode!(text)

    assert message =~ "checks are still pending"
  end

  test "linear_graphql blocks Human Review transition when bot feedback appears after head commit" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => issue_state_update_query(),
          "variables" => %{"issueId" => "issue-123", "stateId" => "state-human-review"}
        },
        linear_client: fn query, _variables, _opts ->
          if query =~ "query SymphonyHumanReviewGateIssue" do
            {:ok, human_review_gate_issue_response("Human Review")}
          else
            flunk("mutation should not run when bot feedback is unresolved")
          end
        end,
        command_runner: fn
          "gh", ["auth", "status"], _opts ->
            {:ok, "ok"}

          "gh", ["pr", "list" | _rest], _opts ->
            {:ok, ~s([{"number":42,"url":"https://github.com/example/repo/pull/42","headRefName":"feat/issue-123"}])}

          "gh", ["pr", "view", "42" | _rest], _opts ->
            {:ok,
             ~s({"number":42,"url":"https://github.com/example/repo/pull/42","state":"OPEN","headRepository":{"nameWithOwner":"example/repo"},"comments":[{"author":{"login":"coderabbitai[bot]","isBot":true},"createdAt":"2026-03-10T11:00:00Z"}],"reviews":[],"commits":[{"committedDate":"2026-03-10T10:00:00Z"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]})}

          "gh", ["api", "repos/example/repo/pulls/42/comments?per_page=100"], _opts ->
            {:ok, "[]"}

          _command, _args, _opts ->
            flunk("unexpected command runner invocation")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert %{
             "error" => %{
               "message" => message
             }
           } = Jason.decode!(text)

    assert message =~ "bot review feedback exists after the latest PR commit"
  end

  test "linear_graphql resolves repository from PR URL when PR metadata omits nameWithOwner" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => issue_state_update_query(),
          "variables" => %{"issueId" => "issue-123", "stateId" => "state-human-review"}
        },
        linear_client: fn query, _variables, _opts ->
          if query =~ "query SymphonyHumanReviewGateIssue" do
            {:ok, human_review_gate_issue_response("Human Review")}
          else
            {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
          end
        end,
        command_runner: fn
          "gh", ["auth", "status"], _opts ->
            {:ok, "ok"}

          "gh", ["pr", "list" | _rest], _opts ->
            {:ok, ~s([{"number":42,"url":"https://github.com/example/repo/pull/42","headRefName":"feat/issue-123"}])}

          "gh", ["pr", "view", "42" | _rest], _opts ->
            {:ok,
             ~s({"number":42,"url":"https://github.com/example/repo/pull/42","state":"OPEN","headRepository":{"nameWithOwner":""},"comments":[],"reviews":[],"commits":[{"committedDate":"2026-03-10T10:00:00Z"}],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]})}

          "gh", ["api", "repos/example/repo/pulls/42/comments?per_page=100"], _opts ->
            {:ok, "[]"}

          _command, _args, _opts ->
            flunk("unexpected command runner invocation")
        end
      )

    assert response["success"] == true
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true

    assert [
             %{
               "text" => ":ok"
             }
           ] = response["contentItems"]
  end

  defp issue_state_update_query do
    """
    mutation MoveIssue($issueId: String!, $stateId: String!) {
      issueUpdate(id: $issueId, input: {stateId: $stateId}) {
        success
      }
    }
    """
  end

  defp issue_state_and_branch_update_query do
    """
    mutation MoveIssueBranch($issueId: String!, $stateId: String!, $branchName: String!) {
      issueUpdate(id: $issueId, input: {stateId: $stateId, branchName: $branchName}) {
        success
      }
    }
    """
  end

  defp human_review_gate_issue_response(
         state_name,
         state_id \\ "state-human-review",
         branch_name \\ "feat/issue-123"
       ) do
    %{
      "data" => %{
        "issue" => %{
          "id" => "issue-123",
          "identifier" => "SYM-123",
          "branchName" => branch_name,
          "team" => %{
            "states" => %{
              "nodes" => [
                %{"id" => state_id, "name" => state_name}
              ]
            }
          }
        }
      }
    }
  end
end
