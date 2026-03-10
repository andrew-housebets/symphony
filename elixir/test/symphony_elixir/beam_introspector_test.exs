defmodule SymphonyElixir.BeamIntrospectorTest do
  use SymphonyElixir.TestSupport

  test "tool execution stats ignore non-tool ETS rows" do
    :ok = SymphonyElixir.BeamIntrospector.reset_tool_stats()

    :ets.insert(:beam_tool_stats, {"good-tool", 2, 2_500, 1_000})
    :ets.insert(:beam_tool_stats, {"bad-count", "oops", 2_500, 1_000})
    :ets.insert(:beam_tool_stats, {"bad-total", 2, -1, 1_000})
    :ets.insert(:beam_tool_stats, {:viewer_count, 7})

    stats = SymphonyElixir.BeamIntrospector.tool_execution_stats()

    assert Enum.any?(stats, fn stat ->
             stat.tool == "good-tool" and stat.call_count == 2 and stat.avg_ms == 1.3 and stat.last_ms == 1.0
           end)

    refute Enum.any?(stats, fn stat -> stat.tool in ["bad-count", "bad-total"] end)
  end
end
