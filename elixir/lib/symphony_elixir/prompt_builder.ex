defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    rendered_prompt =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map(),
          "token_budget" => Config.token_budget_settings() |> Map.new(fn {key, value} -> {to_string(key), value} end)
        },
        @render_opts
      )
      |> IO.iodata_to_binary()

    append_budget_guidance(rendered_prompt)
  end

  @spec budget_guidance(keyword()) :: String.t()
  def budget_guidance(opts \\ []) do
    settings = Config.token_budget_settings()
    run_total_tokens = Keyword.get(opts, :run_total_tokens, 0)
    issue_window_tokens = Keyword.get(opts, :issue_window_tokens, run_total_tokens)

    if settings.enabled do
      remaining_run_hard = max(settings.per_run_hard_tokens - max(run_total_tokens, 0), 0)
      remaining_issue_window_hard = max(settings.per_issue_window_hard_tokens - max(issue_window_tokens, 0), 0)

      [
        "Token budget guidance:",
        "- Target budget: keep this turn under #{format_integer(settings.per_turn_soft_tokens)} tokens and this run under #{format_integer(settings.per_run_soft_tokens)} tokens when possible.",
        "- Hard caps: #{format_integer(settings.per_turn_hard_tokens)} tokens per turn, #{format_integer(settings.per_run_hard_tokens)} tokens per run, and #{format_integer(settings.per_issue_window_hard_tokens)} tokens per issue over #{settings.issue_window_seconds}s.",
        maybe_live_budget_line(run_total_tokens, remaining_run_hard, remaining_issue_window_hard),
        "- Be concise: do not restate ticket context unnecessarily, keep plans short, and summarize tool output unless the raw detail is necessary to act."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    else
      ""
    end
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp append_budget_guidance(prompt) when is_binary(prompt) do
    budget_guidance = budget_guidance()

    if budget_guidance == "" do
      prompt
    else
      String.trim_trailing(prompt) <> "\n\n" <> budget_guidance
    end
  end

  defp format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp maybe_live_budget_line(run_total_tokens, remaining_run_hard, remaining_issue_window_hard)
       when is_integer(run_total_tokens) and run_total_tokens > 0 do
    "- Current run usage so far: #{format_integer(run_total_tokens)} tokens. Remaining before hard stops: #{format_integer(remaining_run_hard)} in this run and #{format_integer(remaining_issue_window_hard)} in the current issue window. A fresh turn can still use up to #{format_integer(Config.token_budget_settings().per_turn_hard_tokens)} tokens, but only if needed."
  end

  defp maybe_live_budget_line(_run_total_tokens, _remaining_run_hard, _remaining_issue_window_hard), do: nil
end
