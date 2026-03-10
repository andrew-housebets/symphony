defmodule SymphonyElixir.BeamIntrospector do
  @moduledoc """
  Gathers BEAM runtime metrics on-demand: memory, scheduler utilization,
  process mailbox depths, and tool execution timing.

  All functions are pure lookups against the runtime — no GenServer needed.
  """

  @tool_stats_table :beam_tool_stats
  @scheduler_prev_key :beam_scheduler_prev

  @monitored_processes [
    {SymphonyElixir.Orchestrator, "Orchestrator"},
    {SymphonyElixir.StatusDashboard, "StatusDashboard"},
    {SymphonyElixir.WorkflowStore, "WorkflowStore"}
  ]

  # ── Public API ──────────────────────────────────────────────────────

  @spec snapshot() :: map()
  def snapshot do
    %{
      memory: memory_breakdown(),
      schedulers: scheduler_utilization(),
      mailboxes: process_mailbox_depths(),
      tool_stats: tool_execution_stats(),
      atoms: atom_table(),
      ports: port_info(),
      uptime_ms: vm_uptime_ms(),
      io: io_stats(),
      gc: gc_stats(),
      viewers: connected_viewers()
    }
  end

  @spec memory_breakdown() :: map()
  def memory_breakdown do
    mem = :erlang.memory()

    %{
      total: Keyword.get(mem, :total, 0),
      processes: Keyword.get(mem, :processes, 0),
      atom: Keyword.get(mem, :atom, 0),
      binary: Keyword.get(mem, :binary, 0),
      ets: Keyword.get(mem, :ets, 0)
    }
  end

  @spec scheduler_utilization() :: [map()]
  def scheduler_utilization do
    current = :erlang.statistics(:scheduler_wall_time)

    prev =
      try do
        :persistent_term.get(@scheduler_prev_key)
      rescue
        ArgumentError -> current
      end

    :persistent_term.put(@scheduler_prev_key, current)

    prev_map = Map.new(prev, fn {id, active, total} -> {id, {active, total}} end)

    current
    |> Enum.map(fn {id, active, total} ->
      {prev_active, prev_total} = Map.get(prev_map, id, {active, total})
      d_active = active - prev_active
      d_total = total - prev_total

      utilization =
        if d_total > 0, do: Float.round(d_active / d_total * 100, 1), else: 0.0

      %{id: id, utilization: utilization}
    end)
    |> Enum.sort_by(& &1.id)
  end

  @spec process_mailbox_depths() :: [map()]
  def process_mailbox_depths do
    Enum.map(@monitored_processes, fn {name, label} ->
      case GenServer.whereis(name) do
        pid when is_pid(pid) ->
          info = Process.info(pid, [:message_queue_len, :memory, :reductions])

          %{
            name: label,
            pid: inspect(pid),
            message_queue_len: get_in(info, [:message_queue_len]) || 0,
            memory: get_in(info, [:memory]) || 0,
            reductions: get_in(info, [:reductions]) || 0
          }

        _ ->
          %{name: label, pid: "not running", message_queue_len: 0, memory: 0, reductions: 0}
      end
    end)
  end

  @spec tool_execution_stats() :: [map()]
  def tool_execution_stats do
    if :ets.whereis(@tool_stats_table) != :undefined do
      :ets.tab2list(@tool_stats_table)
      |> Enum.reduce([], fn row, acc ->
        case normalize_tool_stat_row(row) do
          {:ok, stat} -> [stat | acc]
          :skip -> acc
        end
      end)
      |> Enum.reverse()
    else
      []
    end
  end

  defp normalize_tool_stat_row({tool_name, count, total_us, last_us})
       when is_binary(tool_name) and is_integer(count) and count >= 0 and is_integer(total_us) and total_us >= 0 and
              is_integer(last_us) and last_us >= 0 do
    avg_ms = if count > 0, do: Float.round(total_us / count / 1_000, 1), else: 0.0

    {:ok,
     %{
       tool: tool_name,
       call_count: count,
       avg_ms: avg_ms,
       last_ms: Float.round(last_us / 1_000, 1),
       total_ms: Float.round(total_us / 1_000, 1)
     }}
  end

  defp normalize_tool_stat_row(_row), do: :skip

  @spec atom_table() :: map()
  def atom_table do
    count = :erlang.system_info(:atom_count)
    limit = :erlang.system_info(:atom_limit)
    usage_percent = if limit > 0, do: Float.round(count / limit * 100, 2), else: 0.0
    %{count: count, limit: limit, usage_percent: usage_percent}
  end

  @spec port_info() :: map()
  def port_info do
    %{count: :erlang.ports() |> length()}
  end

  @spec vm_uptime_ms() :: non_neg_integer()
  def vm_uptime_ms do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    uptime_ms
  end

  @spec io_stats() :: map()
  def io_stats do
    {{:input, input_bytes}, {:output, output_bytes}} = :erlang.statistics(:io)
    %{input_bytes: input_bytes, output_bytes: output_bytes}
  end

  @spec gc_stats() :: map()
  def gc_stats do
    {count, words_reclaimed, _} = :erlang.statistics(:garbage_collection)
    %{count: count, words_reclaimed: words_reclaimed}
  end

  @spec connected_viewers() :: non_neg_integer()
  def connected_viewers do
    if :ets.whereis(@tool_stats_table) != :undefined do
      case :ets.lookup(@tool_stats_table, :viewer_count) do
        [{:viewer_count, count}] -> count
        _ -> 0
      end
    else
      0
    end
  end

  @spec increment_viewers() :: non_neg_integer()
  def increment_viewers do
    if :ets.whereis(@tool_stats_table) != :undefined do
      :ets.update_counter(@tool_stats_table, :viewer_count, {2, 1})
    else
      0
    end
  end

  @spec decrement_viewers() :: non_neg_integer()
  def decrement_viewers do
    if :ets.whereis(@tool_stats_table) != :undefined do
      :ets.update_counter(@tool_stats_table, :viewer_count, {2, -1, 0, 0})
    else
      0
    end
  end

  @spec reset_tool_stats() :: :ok
  def reset_tool_stats do
    if :ets.whereis(@tool_stats_table) != :undefined do
      viewer_count = connected_viewers()
      :ets.delete_all_objects(@tool_stats_table)
      :ets.insert(@tool_stats_table, {:viewer_count, viewer_count})
    end

    :ok
  end

  # ── Recording tool executions (called from DynamicTool) ────────────

  @spec record_tool_execution(String.t(), non_neg_integer()) :: true
  def record_tool_execution(tool_name, elapsed_us) do
    if :ets.whereis(@tool_stats_table) != :undefined do
      :ets.insert_new(@tool_stats_table, {tool_name, 0, 0, 0})

      :ets.update_counter(@tool_stats_table, tool_name, [
        {2, 1},
        {3, elapsed_us}
      ])

      :ets.update_element(@tool_stats_table, tool_name, {4, elapsed_us})
    else
      true
    end
  end

  # ── Setup (called from Application.start) ──────────────────────────

  @spec setup() :: :ok
  def setup do
    :erlang.system_flag(:scheduler_wall_time, true)
    :persistent_term.put(@scheduler_prev_key, :erlang.statistics(:scheduler_wall_time))
    :ets.new(@tool_stats_table, [:named_table, :public, :set])
    :ets.insert(@tool_stats_table, {:viewer_count, 0})
    restore_persisted_tool_stats()
    :ok
  end

  defp restore_persisted_tool_stats do
    case SymphonyElixir.StatsPersistence.load() do
      {:ok, %{"tool_stats" => tool_stats}} when is_list(tool_stats) ->
        Enum.each(tool_stats, fn
          %{"tool" => name} = entry when is_binary(name) ->
            count = Map.get(entry, "call_count", 0)
            total_us = trunc(Map.get(entry, "total_ms", 0) * 1_000)
            last_us = trunc(Map.get(entry, "last_ms", 0) * 1_000)
            :ets.insert(@tool_stats_table, {name, count, total_us, last_us})

          _ ->
            :ok
        end)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
