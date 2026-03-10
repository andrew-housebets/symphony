defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Multi-page live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.BeamIntrospector
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:stdout_open, %{})

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      BeamIntrospector.increment_viewers()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, _socket) do
    BeamIntrospector.decrement_viewers()
    :ok
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("reset_stats", _params, socket) do
    SymphonyElixir.Orchestrator.reset_stats()
    {:noreply, assign(socket, :payload, load_payload())}
  end

  @impl true
  def handle_event("toggle_stdout", %{"issue" => issue_id}, socket) do
    stdout_open = socket.assigns.stdout_open

    stdout_open =
      if Map.has_key?(stdout_open, issue_id) do
        Map.delete(stdout_open, issue_id)
      else
        Map.put(stdout_open, issue_id, fetch_stdout(issue_id))
      end

    {:noreply, assign(socket, :stdout_open, stdout_open)}
  end

  # ── Render dispatch ────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <%= case @live_action do %>
      <% :overview -> %>
        <.render_overview payload={@payload} now={@now} stdout_open={@stdout_open} />
      <% :sessions -> %>
        <.render_sessions payload={@payload} now={@now} />
      <% :beam -> %>
        <.render_beam payload={@payload} />
      <% _ -> %>
        <.render_overview payload={@payload} now={@now} stdout_open={@stdout_open} />
    <% end %>
    """
  end

  # ── Overview page ──────────────────────────────────────────────────

  defp render_overview(assigns) do
    ~H"""
    <div class="page">
      <header class="page-header">
        <div>
          <h1 class="page-title">Overview</h1>
          <p class="page-desc">Orchestration health, token usage, and active session state.</p>
        </div>
        <div class="header-badges">
          <span class="live-badge">
            <span class="live-dot"></span>
            Live
          </span>
          <span :if={@payload[:beam]} class="viewer-badge">
            <%= @payload.beam.viewers %> viewer<%= if @payload.beam.viewers != 1, do: "s" %>
          </span>
          <button type="button" class="reset-stats-btn" phx-click="reset_stats"
                  data-confirm="Reset all runtime statistics? This cannot be undone.">
            Reset Stats
          </button>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <div class="alert alert-error">
          <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
        </div>
      <% else %>
        <div class="kpi-grid">
          <div class="kpi-card">
            <span class="kpi-label">Running</span>
            <span class="kpi-value numeric"><%= @payload.counts.running %></span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Retrying</span>
            <span class="kpi-value numeric"><%= @payload.counts.retrying %></span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Total tokens</span>
            <span class="kpi-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></span>
            <span class="kpi-sub numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Runtime</span>
            <span class="kpi-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></span>
          </div>
          <div :if={@payload[:session_stats]} class="kpi-card">
            <span class="kpi-label">Success rate</span>
            <span class="kpi-value numeric"><%= @payload.session_stats.success_rate %>%</span>
            <span class="kpi-sub numeric">
              <%= @payload.session_stats.total_completed %> ok / <%= @payload.session_stats.total_failed %> failed
            </span>
          </div>
          <div :if={beam_uptime(@payload)} class="kpi-card">
            <span class="kpi-label">VM uptime</span>
            <span class="kpi-value numeric"><%= format_uptime(@payload.beam.uptime_ms) %></span>
          </div>
        </div>

        <div class="card">
          <div class="card-header">
            <h2 class="card-title">Rate limits</h2>
          </div>
          <div class="card-body">
            <div class="kv-grid">
              <span class="kv-label">Configured model</span>
              <span class="kv-value mono"><%= display_model(@payload.requested_model) %></span>
              <span class="kv-label">Runtime model</span>
              <span class="kv-value mono"><%= display_model(@payload.effective_model) %></span>
              <span class="kv-label">Bucket ID</span>
              <span class="kv-value mono"><%= display_model(@payload.rate_limit_bucket_id) %></span>
              <span class="kv-label">Bucket label</span>
              <span class="kv-value mono"><%= display_model(@payload.rate_limit_bucket_model) %></span>
            </div>

            <%= if rate_limit_rows(@payload) != [] do %>
              <div class="table-wrap">
                <table class="table">
                  <thead>
                    <tr>
                      <th>Bucket ID</th>
                      <th>Label</th>
                      <th>Primary</th>
                      <th>Secondary</th>
                      <th>Credits</th>
                      <th>Plan</th>
                      <th>Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- rate_limit_rows(@payload)}>
                      <td class="mono"><%= row.bucket_id %></td>
                      <td class="mono"><%= row.bucket_label %></td>
                      <td class="mono"><%= row.primary %></td>
                      <td class="mono"><%= row.secondary %></td>
                      <td><%= row.credits %></td>
                      <td><%= row.plan_type %></td>
                      <td><%= row.status %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% else %>
              <p class="empty">No rate-limit buckets reported yet.</p>
            <% end %>
          </div>
        </div>

        <div class="card">
          <div class="card-header">
            <h2 class="card-title">Running sessions</h2>
            <span class="card-badge numeric"><%= length(@payload.running) %></span>
          </div>
          <div class="card-body">
            <%= if @payload.running == [] do %>
              <p class="empty">No active sessions.</p>
            <% else %>
              <div class="table-wrap">
                <table class="table table-running">
                  <colgroup>
                    <col style="width: 11rem;" />
                    <col style="width: 7rem;" />
                    <col style="width: 8rem;" />
                    <col />
                    <col style="width: 10rem;" />
                    <col style="width: 5rem;" />
                  </colgroup>
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>State</th>
                      <th>Runtime</th>
                      <th>Last update</th>
                      <th>Tokens</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody :for={entry <- @payload.running}>
                    <tr>
                      <td>
                        <div class="cell-stack">
                          <span class="cell-primary"><%= entry.issue_identifier %></span>
                          <div class="cell-actions">
                            <a class="link-muted" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                            <%= if entry.session_id do %>
                              <button
                                type="button"
                                class="btn-ghost"
                                data-label="Copy SID"
                                data-copy={entry.session_id}
                                onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._t); this._t = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                              >
                                Copy SID
                              </button>
                            <% end %>
                          </div>
                        </div>
                      </td>
                      <td><span class={badge_class(entry.state)}><%= entry.state %></span></td>
                      <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                      <td>
                        <div class="cell-stack">
                          <span class="cell-primary ellipsis" title={entry.last_message || to_string(entry.last_event || "n/a")}>
                            <%= entry.last_message || to_string(entry.last_event || "n/a") %>
                          </span>
                          <span class="cell-secondary">
                            <%= entry.last_event || "n/a" %>
                            <%= if entry.last_event_at, do: Phoenix.HTML.raw(" &middot; #{entry.last_event_at}") %>
                          </span>
                        </div>
                      </td>
                      <td>
                        <div class="cell-stack numeric">
                          <span><%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="cell-secondary">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                        </div>
                      </td>
                      <td>
                        <%= if entry.session_id && Map.get(entry, :stdout_line_count, 0) > 0 do %>
                          <button
                            type="button"
                            class="btn-toggle"
                            phx-click="toggle_stdout"
                            phx-value-issue={entry.issue_identifier}
                            aria-expanded={if Map.has_key?(@stdout_open, entry.issue_identifier), do: "true", else: "false"}
                          >
                            <span class="toggle-icon"><%= if Map.has_key?(@stdout_open, entry.issue_identifier), do: "▾", else: "▸" %></span>
                            Log
                          </button>
                        <% else %>
                          <span class="text-muted" style="font-size: 0.78rem;">--</span>
                        <% end %>
                      </td>
                    </tr>
                    <%= if Map.has_key?(@stdout_open, entry.issue_identifier) do %>
                      <tr class="stdout-expansion">
                        <td colspan="6" class="stdout-expansion-cell">
                          <div class="log-panel">
                            <div class="log-panel-header">
                              <span class="log-panel-title">session log</span>
                              <span class="log-panel-meta"><%= entry.issue_identifier %></span>
                            </div>
                            <pre class="log-content" id={"stdout-#{entry.issue_identifier}"} phx-hook="ScrollBottom"><%= Map.get(@stdout_open, entry.issue_identifier, "") %></pre>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>

        <div class="card">
          <div class="card-header">
            <h2 class="card-title">Retry queue</h2>
            <span class="card-badge numeric"><%= length(@payload.retrying) %></span>
          </div>
          <div class="card-body">
            <%= if @payload.retrying == [] do %>
              <p class="empty">No issues are currently backing off.</p>
            <% else %>
              <div class="table-wrap">
                <table class="table">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>Attempt</th>
                      <th>Due at</th>
                      <th>Error</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.retrying}>
                      <td>
                        <div class="cell-stack">
                          <span class="cell-primary"><%= entry.issue_identifier %></span>
                          <a class="link-muted" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                        </div>
                      </td>
                      <td class="numeric"><%= entry.attempt %></td>
                      <td class="mono"><%= entry.due_at || "n/a" %></td>
                      <td><%= entry.error || "n/a" %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Sessions page ──────────────────────────────────────────────────

  defp render_sessions(assigns) do
    ~H"""
    <div class="page">
      <header class="page-header">
        <div>
          <h1 class="page-title">Sessions</h1>
          <p class="page-desc">Active, completed, and failed agent sessions with per-session metrics.</p>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <div class="alert alert-error">
          <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
        </div>
      <% else %>
        <div :if={@payload[:session_stats]} class="kpi-grid">
          <div class="kpi-card kpi-success">
            <span class="kpi-label">Completed</span>
            <span class="kpi-value numeric"><%= @payload.session_stats.total_completed %></span>
          </div>
          <div class="kpi-card kpi-danger">
            <span class="kpi-label">Failed</span>
            <span class="kpi-value numeric"><%= @payload.session_stats.total_failed %></span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Success rate</span>
            <span class="kpi-value numeric"><%= @payload.session_stats.success_rate %>%</span>
          </div>
          <div :if={@payload[:poll_stats]} class="kpi-card">
            <span class="kpi-label">Last poll</span>
            <span class="kpi-value numeric"><%= format_poll_duration(@payload.poll_stats) %></span>
            <span class="kpi-sub numeric">
              interval <%= format_int(Map.get(@payload.poll_stats, :interval_ms, 0)) %> ms
            </span>
          </div>
        </div>

        <div class="card">
          <div class="card-header">
            <h2 class="card-title">Active sessions</h2>
            <span class="card-badge numeric"><%= length(@payload.running) %></span>
          </div>
          <div class="card-body">
            <%= if @payload.running == [] do %>
              <p class="empty">No active sessions.</p>
            <% else %>
              <div class="table-wrap">
                <table class="table">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>State</th>
                      <th>Runtime</th>
                      <th>Turns</th>
                      <th>Tokens</th>
                      <th>Memory</th>
                      <th>Last event</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.running}>
                      <td class="cell-primary"><%= entry.issue_identifier %></td>
                      <td><span class={badge_class(entry.state)}><%= entry.state %></span></td>
                      <td class="numeric"><%= format_runtime_seconds(runtime_seconds_from_started_at(entry.started_at, @now)) %></td>
                      <td class="numeric"><%= Map.get(entry, :turn_count, 0) %></td>
                      <td class="numeric"><%= format_int(entry.tokens.total_tokens) %></td>
                      <td class="numeric"><%= format_bytes(Map.get(entry, :process_memory, 0)) %></td>
                      <td class="mono cell-secondary"><%= entry.last_event || "n/a" %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>

        <div :if={completed_sessions(@payload) != []} class="card">
          <div class="card-header">
            <h2 class="card-title">Recently completed</h2>
            <span class="card-badge numeric"><%= length(completed_sessions(@payload)) %></span>
          </div>
          <div class="card-body">
            <div class="table-wrap">
              <table class="table">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Outcome</th>
                    <th>Runtime</th>
                    <th>Turns</th>
                    <th>Tokens</th>
                    <th>Completed</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={session <- completed_sessions(@payload)}>
                    <td class="cell-primary"><%= session.identifier %></td>
                    <td>
                      <span class={outcome_badge_class(session.outcome)}>
                        <%= session.outcome %>
                      </span>
                    </td>
                    <td class="numeric"><%= format_runtime_seconds(session.runtime_seconds) %></td>
                    <td class="numeric"><%= session.turn_count %></td>
                    <td class="numeric"><%= format_int(session.total_tokens) %></td>
                    <td class="mono cell-secondary"><%= format_completed_at(session.completed_at) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── BEAM runtime page ──────────────────────────────────────────────

  defp render_beam(assigns) do
    ~H"""
    <div class="page">
      <header class="page-header">
        <div>
          <h1 class="page-title">BEAM Runtime</h1>
          <p class="page-desc">Erlang VM introspection: memory, schedulers, processes, atoms, IO, and GC.</p>
        </div>
      </header>

      <%= if @payload[:error] || !@payload[:beam] do %>
        <div class="alert alert-error">
          BEAM metrics unavailable.
        </div>
      <% else %>
        <div class="kpi-grid">
          <div class="kpi-card">
            <span class="kpi-label">VM uptime</span>
            <span class="kpi-value numeric"><%= format_uptime(@payload.beam.uptime_ms) %></span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Total memory</span>
            <span class="kpi-value numeric"><%= format_bytes(@payload.beam.memory.total) %></span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Processes</span>
            <span class="kpi-value numeric"><%= format_int(length(:erlang.processes())) %></span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Ports</span>
            <span class="kpi-value numeric"><%= @payload.beam.ports.count %></span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Viewers</span>
            <span class="kpi-value numeric"><%= @payload.beam.viewers %></span>
          </div>
        </div>

        <div class="grid-2col">
          <div class="card">
            <div class="card-header">
              <h2 class="card-title">Memory breakdown</h2>
            </div>
            <div class="card-body">
              <div class="beam-mem-grid">
                <div :for={{label, key} <- beam_memory_fields()} class="beam-mem-item">
                  <span class="beam-mem-label"><%= label %></span>
                  <span class="beam-mem-val numeric"><%= format_bytes(@payload.beam.memory[key]) %></span>
                </div>
              </div>
            </div>
          </div>

          <div class="card">
            <div class="card-header">
              <h2 class="card-title">Atom table</h2>
            </div>
            <div class="card-body">
              <div class="atom-gauge">
                <div class="gauge-track">
                  <div class={atom_gauge_class(@payload.beam.atoms.usage_percent)} style={"width: #{min(@payload.beam.atoms.usage_percent, 100)}%"}></div>
                </div>
                <div class="gauge-labels">
                  <span class="numeric"><%= format_int(@payload.beam.atoms.count) %> used</span>
                  <span class="text-muted numeric"><%= format_int(@payload.beam.atoms.limit) %> limit</span>
                </div>
                <span class={"gauge-pct numeric #{atom_pct_class(@payload.beam.atoms.usage_percent)}"}><%= Float.round(@payload.beam.atoms.usage_percent, 1) %>%</span>
              </div>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-header">
            <h2 class="card-title">Scheduler utilization</h2>
          </div>
          <div class="card-body">
            <div class="sched-grid">
              <div :for={sched <- @payload.beam.schedulers} class="sched-row">
                <span class="sched-id numeric"><%= sched.id %></span>
                <div class="sched-track">
                  <div class={sched_fill_class(sched.utilization)} style={"width: #{min(sched.utilization, 100)}%"}></div>
                </div>
                <span class={"sched-pct numeric #{sched_pct_class(sched.utilization)}"}><%= sched.utilization %>%</span>
              </div>
            </div>
          </div>
        </div>

        <div class="grid-2col">
          <div class="card">
            <div class="card-header">
              <h2 class="card-title">Process health</h2>
            </div>
            <div class="card-body">
              <div class="table-wrap">
                <table class="table table-compact">
                  <thead>
                    <tr>
                      <th>Process</th>
                      <th>PID</th>
                      <th>Mailbox</th>
                      <th>Memory</th>
                      <th>Reductions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={proc <- @payload.beam.mailboxes}>
                      <td class="mono"><%= proc.name %></td>
                      <td class="mono text-muted"><%= proc.pid %></td>
                      <td>
                        <span class={mailbox_badge_class(proc.message_queue_len)}>
                          <%= proc.message_queue_len %>
                        </span>
                      </td>
                      <td class="numeric"><%= format_bytes(proc.memory) %></td>
                      <td class="numeric"><%= format_int(proc.reductions) %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <div class="card">
            <div class="card-header">
              <h2 class="card-title">IO &amp; GC</h2>
            </div>
            <div class="card-body">
              <div class="kv-grid">
                <span class="kv-label">IO input</span>
                <span class="kv-value numeric"><%= format_bytes(@payload.beam.io.input_bytes) %></span>
                <span class="kv-label">IO output</span>
                <span class="kv-value numeric"><%= format_bytes(@payload.beam.io.output_bytes) %></span>
                <span class="kv-label">GC runs</span>
                <span class="kv-value numeric"><%= format_int(@payload.beam.gc.count) %></span>
                <span class="kv-label">GC reclaimed</span>
                <span class="kv-value numeric"><%= format_bytes(@payload.beam.gc.words_reclaimed * 8) %></span>
              </div>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-header">
            <h2 class="card-title">Tool execution</h2>
          </div>
          <div class="card-body">
            <%= if @payload.beam.tool_stats == [] do %>
              <p class="empty">No tool executions recorded yet.</p>
            <% else %>
              <div class="table-wrap">
                <table class="table table-compact">
                  <thead>
                    <tr>
                      <th>Tool</th>
                      <th>Calls</th>
                      <th>Avg</th>
                      <th>Last</th>
                      <th>Total</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={tool <- @payload.beam.tool_stats}>
                      <td class="mono"><%= tool.tool %></td>
                      <td class="numeric"><%= format_int(tool.call_count) %></td>
                      <td class="numeric"><%= tool.avg_ms %> ms</td>
                      <td class="numeric"><%= tool.last_ms %> ms</td>
                      <td class="numeric"><%= format_int(trunc(tool.total_ms)) %> ms</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Data helpers ───────────────────────────────────────────────────

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp fetch_stdout(issue_identifier) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, %{logs: %{codex_session_logs: logs}}} when is_list(logs) ->
        logs
        |> Enum.map(&format_stdout_entry/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      _ ->
        ""
    end
  end

  defp completed_sessions(payload), do: Map.get(payload, :completed_sessions, [])

  defp beam_uptime(payload) do
    case payload do
      %{beam: %{uptime_ms: ms}} when is_integer(ms) -> true
      _ -> false
    end
  end

  # ── Formatting helpers ─────────────────────────────────────────────

  defp total_runtime_seconds(payload, now) do
    completed = payload.codex_totals.seconds_running || 0

    completed +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}t"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole = max(trunc(seconds), 0)

    cond do
      whole >= 3600 ->
        h = div(whole, 3600)
        m = div(rem(whole, 3600), 60)
        "#{h}h #{m}m"

      true ->
        m = div(whole, 60)
        s = rem(whole, 60)
        "#{m}m #{s}s"
    end
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now),
    do: DateTime.diff(now, started_at, :second)

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_uptime(ms) when is_integer(ms) do
    total_s = div(ms, 1_000)
    h = div(total_s, 3600)
    m = div(rem(total_s, 3600), 60)
    s = rem(total_s, 60)

    cond do
      h > 0 -> "#{h}h #{m}m #{s}s"
      m > 0 -> "#{m}m #{s}s"
      true -> "#{s}s"
    end
  end

  defp format_uptime(_ms), do: "n/a"

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_024,
    do: "#{Float.round(bytes / 1_024, 1)} KB"

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "n/a"

  defp format_poll_duration(%{last_duration_ms: ms}) when is_integer(ms), do: "#{ms} ms"
  defp format_poll_duration(_), do: "n/a"

  defp format_completed_at(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_completed_at(_), do: "n/a"

  defp format_stdout_entry(%{at: at, text: text}) when is_binary(text) do
    case at do
      ts when is_binary(ts) and ts != "" -> "[#{ts}] #{text}"
      _ -> text
    end
  end

  defp format_stdout_entry(%{"at" => at, "text" => text}) when is_binary(text) do
    case at do
      ts when is_binary(ts) and ts != "" -> "[#{ts}] #{text}"
      _ -> text
    end
  end

  defp format_stdout_entry(_), do: ""

  # ── Badge/class helpers ────────────────────────────────────────────

  defp badge_class(state) do
    n = state |> to_string() |> String.downcase()

    cond do
      String.contains?(n, ["progress", "running", "active"]) -> "badge badge-success"
      String.contains?(n, ["blocked", "error", "failed"]) -> "badge badge-danger"
      String.contains?(n, ["todo", "queued", "pending", "retry"]) -> "badge badge-warning"
      true -> "badge"
    end
  end

  defp outcome_badge_class(:success), do: "badge badge-success"
  defp outcome_badge_class(:failure), do: "badge badge-danger"
  defp outcome_badge_class(_), do: "badge"

  defp sched_fill_class(u) when u >= 80, do: "sched-fill sched-fill-danger"
  defp sched_fill_class(u) when u >= 50, do: "sched-fill sched-fill-warn"
  defp sched_fill_class(_), do: "sched-fill"

  defp sched_pct_class(u) when u >= 80, do: "text-danger"
  defp sched_pct_class(u) when u >= 50, do: "text-warn"
  defp sched_pct_class(_), do: ""

  defp atom_gauge_class(p) when p >= 80, do: "gauge-fill gauge-fill-danger"
  defp atom_gauge_class(p) when p >= 50, do: "gauge-fill gauge-fill-warn"
  defp atom_gauge_class(_), do: "gauge-fill"

  defp atom_pct_class(p) when p >= 80, do: "text-danger"
  defp atom_pct_class(p) when p >= 50, do: "text-warn"
  defp atom_pct_class(_), do: ""

  defp mailbox_badge_class(n) when n >= 100, do: "mbx-badge mbx-danger numeric"
  defp mailbox_badge_class(n) when n >= 10, do: "mbx-badge mbx-warn numeric"
  defp mailbox_badge_class(_), do: "mbx-badge mbx-ok numeric"

  defp display_model(nil), do: "n/a"
  defp display_model(v) when is_binary(v), do: v
  defp display_model(v), do: to_string(v)

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  # ── Rate limit helpers ─────────────────────────────────────────────

  defp rate_limit_rows(payload) when is_map(payload) do
    rows =
      payload
      |> Map.get(:rate_limit_buckets, [])
      |> List.wrap()
      |> Enum.map(&rate_limit_row_from_entry/1)
      |> Enum.reject(&is_nil/1)

    if rows == [] do
      case fallback_rate_limit_row(payload) do
        nil -> []
        row -> [row]
      end
    else
      rows
    end
  end

  defp rate_limit_rows(_), do: []

  defp fallback_rate_limit_row(%{rate_limits: %{} = rl} = p) do
    rate_limit_row(Map.get(p, :rate_limit_bucket_id), Map.get(p, :rate_limit_bucket_model), rl, true, true)
  end

  defp fallback_rate_limit_row(_), do: nil

  defp rate_limit_row_from_entry(%{rate_limits: %{} = rl} = e) do
    rate_limit_row(Map.get(e, :bucket_id), Map.get(e, :bucket_label), rl, Map.get(e, :selected) == true, Map.get(e, :latest) == true)
  end

  defp rate_limit_row_from_entry(_), do: nil

  defp rate_limit_row(bucket_id, bucket_label, rl, selected?, latest?) when is_map(rl) do
    %{
      bucket_id: display_model(bucket_id),
      bucket_label: display_model(bucket_label),
      primary: fmt_rl_window(rlv(rl, ["primary", :primary])),
      secondary: fmt_rl_window(rlv(rl, ["secondary", :secondary])),
      credits: fmt_rl_credits(rlv(rl, ["credits", :credits])),
      plan_type: fmt_rl_plan(rl),
      status: fmt_rl_status(selected?, latest?)
    }
  end

  defp rate_limit_row(_, _, _, _, _), do: nil

  defp fmt_rl_status(true, true), do: "selected, latest"
  defp fmt_rl_status(true, false), do: "selected"
  defp fmt_rl_status(false, true), do: "latest"
  defp fmt_rl_status(false, false), do: "tracked"

  defp fmt_rl_plan(rl) when is_map(rl) do
    case rlv(rl, ["plan_type", :plan_type, "planType", :planType]) do
      v when is_binary(v) -> if String.trim(v) == "", do: "n/a", else: String.trim(v)
      nil -> "n/a"
      o -> to_string(o)
    end
  end

  defp fmt_rl_plan(_), do: "n/a"

  defp fmt_rl_window(w) when is_map(w) do
    pct = rlv(w, ["used_percent", :used_percent, "usedPercent", :usedPercent])
    mins = rlv(w, ["window_minutes", :window_minutes, "windowDurationMins", :windowDurationMins])
    resets = rlv(w, ["resets_at", :resets_at, "resetsAt", :resetsAt])

    pct_t =
      cond do
        is_integer(pct) -> "#{pct}%"
        is_float(pct) -> "#{Float.round(pct, 1)}%"
        true -> "n/a"
      end

    mins_t = if is_integer(mins), do: "#{mins}m", else: "n/a"
    reset_t = fmt_rl_reset(resets)
    "#{pct_t} / #{mins_t} / #{reset_t}"
  end

  defp fmt_rl_window(_), do: "n/a"

  defp fmt_rl_reset(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M UTC")
      _ -> "n/a"
    end
  end

  defp fmt_rl_reset(_), do: "n/a"

  defp fmt_rl_credits(c) when is_map(c) do
    unlimited = rlv(c, ["unlimited", :unlimited]) == true
    has = rlv(c, ["has_credits", :has_credits, "hasCredits", :hasCredits]) == true
    bal = rlv(c, ["balance", :balance])

    cond do
      unlimited -> "unlimited"
      has and is_number(bal) -> "#{bal}"
      has -> "available"
      true -> "none"
    end
  end

  defp fmt_rl_credits(_), do: "n/a"

  defp rlv(m, keys) when is_map(m) and is_list(keys) do
    Enum.find_value(keys, fn k -> if Map.has_key?(m, k), do: Map.get(m, k) end)
  end

  defp rlv(_, _), do: nil

  defp beam_memory_fields do
    [{"Total", :total}, {"Processes", :processes}, {"Atoms", :atom}, {"Binary", :binary}, {"ETS", :ets}]
  end
end
