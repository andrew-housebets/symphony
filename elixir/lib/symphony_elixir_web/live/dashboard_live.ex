defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">
                Configured/runtime model identity plus upstream quota-bucket metadata from the latest rate-limit snapshot.
              </p>
            </div>
          </div>

          <p class="section-copy">
            Configured model: <span class="mono"><%= display_model(@payload.requested_model) %></span>
          </p>
          <p class="section-copy">
            Runtime-reported model: <span class="mono"><%= display_model(@payload.effective_model) %></span>
          </p>
          <p class="section-copy">
            Selected upstream bucket id: <span class="mono"><%= display_model(@payload.rate_limit_bucket_id) %></span>
          </p>
          <p class="section-copy">
            Selected upstream bucket label: <span class="mono"><%= display_model(@payload.rate_limit_bucket_model) %></span>
          </p>
          <p :if={bucket_differs_from_models?(@payload)} class="section-copy">
            Note: bucket labels are upstream quota tiers and can differ from model IDs.
          </p>

          <%= if rate_limit_rows(@payload) == [] do %>
            <p class="empty-state">No rate-limit buckets reported yet.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 980px;">
                <thead>
                  <tr>
                    <th>Bucket ID</th>
                    <th>Bucket label</th>
                    <th>Primary window</th>
                    <th>Secondary window</th>
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
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 7rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                  <col style="width: 6rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody :for={entry <- @payload.running}>
                  <tr>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <div class="issue-actions">
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                          <%= if entry.session_id do %>
                            <button
                              type="button"
                              class="subtle-button"
                              data-label="Copy SID"
                              data-copy={entry.session_id}
                              onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                            >
                              Copy SID
                            </button>
                          <% end %>
                        </div>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                    <td>
                      <%= if entry.session_id && stdout_line_count(entry.stdout) > 0 do %>
                        <button
                          type="button"
                          class="stdout-toggle-btn"
                          onclick={"
                            const row = this.closest('tr').nextElementSibling;
                            const isOpen = row.classList.toggle('stdout-row-open');
                            this.setAttribute('aria-expanded', isOpen);
                            this.querySelector('.stdout-toggle-icon').textContent = isOpen ? '▾' : '▸';
                          "}
                          aria-expanded="false"
                        >
                          <span class="stdout-toggle-icon">▸</span>
                          Stdout
                          <span class="stdout-count"><%= stdout_line_count(entry.stdout) %></span>
                        </button>
                      <% else %>
                        <span class="muted" style="font-size: 0.78rem;">—</span>
                      <% end %>
                    </td>
                  </tr>
                  <tr class="stdout-row">
                    <td colspan="6" class="stdout-cell">
                      <div class="stdout-panel">
                        <div class="stdout-panel-header">
                          <span class="stdout-panel-title">stdout · <%= entry.issue_identifier %></span>
                          <span class="stdout-panel-count"><%= stdout_line_count(entry.stdout) %> lines</span>
                        </div>
                        <%= if stdout_line_count(entry.stdout) == 0 do %>
                          <p class="stdout-empty muted">No stdout captured yet.</p>
                        <% else %>
                          <pre class="stdout-log"><%= format_stdout(entry.stdout) %></pre>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
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
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp stdout_line_count(stdout_entries) when is_list(stdout_entries), do: length(stdout_entries)
  defp stdout_line_count(_stdout_entries), do: 0

  defp format_stdout(stdout_entries) when is_list(stdout_entries) do
    stdout_entries
    |> Enum.map(&format_stdout_entry/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_stdout(_stdout_entries), do: ""

  defp format_stdout_entry(%{at: at, text: text}) when is_binary(text) do
    case at do
      timestamp when is_binary(timestamp) and timestamp != "" -> "[#{timestamp}] #{text}"
      _ -> text
    end
  end

  defp format_stdout_entry(%{"at" => at, "text" => text}) when is_binary(text) do
    case at do
      timestamp when is_binary(timestamp) and timestamp != "" -> "[#{timestamp}] #{text}"
      _ -> text
    end
  end

  defp format_stdout_entry(_entry), do: ""

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp display_model(nil), do: "n/a"
  defp display_model(value) when is_binary(value), do: value
  defp display_model(value), do: to_string(value)

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

  defp rate_limit_rows(_payload), do: []

  defp fallback_rate_limit_row(payload) when is_map(payload) do
    case Map.get(payload, :rate_limits) do
      %{} = rate_limits ->
        rate_limit_row(
          Map.get(payload, :rate_limit_bucket_id),
          Map.get(payload, :rate_limit_bucket_model),
          rate_limits,
          true,
          true
        )

      _ ->
        nil
    end
  end

  defp fallback_rate_limit_row(_payload), do: nil

  defp rate_limit_row_from_entry(entry) when is_map(entry) do
    rate_limits = Map.get(entry, :rate_limits)

    if is_map(rate_limits) do
      rate_limit_row(
        Map.get(entry, :bucket_id),
        Map.get(entry, :bucket_label),
        rate_limits,
        Map.get(entry, :selected) == true,
        Map.get(entry, :latest) == true
      )
    end
  end

  defp rate_limit_row_from_entry(_entry), do: nil

  defp rate_limit_row(bucket_id, bucket_label, rate_limits, selected?, latest?) when is_map(rate_limits) do
    %{
      bucket_id: display_model(bucket_id),
      bucket_label: display_model(bucket_label),
      primary: format_rate_limit_window(rate_limit_map_value(rate_limits, ["primary", :primary])),
      secondary: format_rate_limit_window(rate_limit_map_value(rate_limits, ["secondary", :secondary])),
      credits: format_rate_limit_credits(rate_limit_map_value(rate_limits, ["credits", :credits])),
      plan_type: format_rate_limit_plan(rate_limits),
      status: format_rate_limit_status(selected?, latest?)
    }
  end

  defp rate_limit_row(_bucket_id, _bucket_label, _rate_limits, _selected?, _latest?), do: nil

  defp format_rate_limit_status(true, true), do: "selected, latest"
  defp format_rate_limit_status(true, false), do: "selected"
  defp format_rate_limit_status(false, true), do: "latest"
  defp format_rate_limit_status(false, false), do: "tracked"

  defp format_rate_limit_plan(rate_limits) when is_map(rate_limits) do
    case rate_limit_map_value(rate_limits, ["plan_type", :plan_type, "planType", :planType]) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: "n/a", else: trimmed

      nil ->
        "n/a"

      other ->
        to_string(other)
    end
  end

  defp format_rate_limit_plan(_rate_limits), do: "n/a"

  defp format_rate_limit_window(window) when is_map(window) do
    used_percent = rate_limit_map_value(window, ["used_percent", :used_percent, "usedPercent", :usedPercent])
    window_minutes = rate_limit_map_value(window, ["window_minutes", :window_minutes, "windowDurationMins", :windowDurationMins])
    resets_at = rate_limit_map_value(window, ["resets_at", :resets_at, "resetsAt", :resetsAt])

    used_text =
      cond do
        is_integer(used_percent) -> "#{used_percent}%"
        is_float(used_percent) -> "#{Float.round(used_percent, 1)}%"
        true -> "n/a"
      end

    window_text = if is_integer(window_minutes), do: "#{window_minutes}m", else: "n/a"
    reset_text = format_rate_limit_reset(resets_at)
    "#{used_text} · #{window_text} · #{reset_text}"
  end

  defp format_rate_limit_window(_window), do: "n/a"

  defp format_rate_limit_reset(unix_seconds) when is_integer(unix_seconds) do
    case DateTime.from_unix(unix_seconds) do
      {:ok, datetime} -> "resets #{Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")}"
      _ -> "reset n/a"
    end
  end

  defp format_rate_limit_reset(_value), do: "reset n/a"

  defp format_rate_limit_credits(credits) when is_map(credits) do
    unlimited = rate_limit_map_value(credits, ["unlimited", :unlimited]) == true
    has_credits = rate_limit_map_value(credits, ["has_credits", :has_credits, "hasCredits", :hasCredits]) == true
    balance = rate_limit_map_value(credits, ["balance", :balance])

    cond do
      unlimited ->
        "unlimited"

      has_credits and is_number(balance) ->
        "balance #{format_number(balance)}"

      has_credits ->
        "available"

      true ->
        "none"
    end
  end

  defp format_rate_limit_credits(_credits), do: "n/a"

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value) when is_float(value), do: Float.to_string(Float.round(value, 2))
  defp format_number(value), do: to_string(value)

  defp rate_limit_map_value(payload, keys) when is_map(payload) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(payload, key), do: Map.get(payload, key)
    end)
  end

  defp rate_limit_map_value(_payload, _keys), do: nil

  defp bucket_differs_from_models?(payload) when is_map(payload) do
    bucket = Map.get(payload, :rate_limit_bucket_model)
    requested = Map.get(payload, :requested_model)
    effective = Map.get(payload, :effective_model)

    is_binary(bucket) and String.trim(bucket) != "" and bucket != requested and bucket != effective
  end

  defp bucket_differs_from_models?(_payload), do: false
end
