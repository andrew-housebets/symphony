defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  alias SymphonyElixirWeb.StaticAssets

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:asset_version, StaticAssets.version())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src={versioned_asset_path("/vendor/phoenix_html/phoenix_html.js", @asset_version)}></script>
        <script defer src={versioned_asset_path("/vendor/phoenix/phoenix.js", @asset_version)}></script>
        <script defer src={versioned_asset_path("/vendor/phoenix_live_view/phoenix_live_view.js", @asset_version)}></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: {
                ScrollBottom: {
                  mounted() { this.el.scrollTop = this.el.scrollHeight; },
                  updated() { this.el.scrollTop = this.el.scrollHeight; }
                }
              }
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href={versioned_asset_path("/dashboard.css", @asset_version)} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <div class="shell">
      <nav class="sidebar">
        <div class="sidebar-brand">
          <span class="sidebar-logo">S</span>
          <span class="sidebar-title">Symphony</span>
        </div>
        <ul class="sidebar-nav">
          <li>
            <.link navigate="/" class="sidebar-link" data-active={if active_page(assigns) == :overview, do: "true"}>
              <svg class="sidebar-icon" viewBox="0 0 20 20" fill="currentColor"><path d="M10.707 2.293a1 1 0 00-1.414 0l-7 7a1 1 0 001.414 1.414L4 10.414V17a1 1 0 001 1h2a1 1 0 001-1v-2a1 1 0 011-1h2a1 1 0 011 1v2a1 1 0 001 1h2a1 1 0 001-1v-6.586l.293.293a1 1 0 001.414-1.414l-7-7z"/></svg>
              Overview
            </.link>
          </li>
          <li>
            <.link navigate="/sessions" class="sidebar-link" data-active={if active_page(assigns) == :sessions, do: "true"}>
              <svg class="sidebar-icon" viewBox="0 0 20 20" fill="currentColor"><path d="M9 2a1 1 0 000 2h2a1 1 0 100-2H9z"/><path fill-rule="evenodd" d="M4 5a2 2 0 012-2 3 3 0 003 3h2a3 3 0 003-3 2 2 0 012 2v11a2 2 0 01-2 2H6a2 2 0 01-2-2V5zm3 4a1 1 0 000 2h.01a1 1 0 100-2H7zm3 0a1 1 0 000 2h3a1 1 0 100-2h-3zm-3 4a1 1 0 100 2h.01a1 1 0 100-2H7zm3 0a1 1 0 100 2h3a1 1 0 100-2h-3z" clip-rule="evenodd"/></svg>
              Sessions
            </.link>
          </li>
          <li>
            <.link navigate="/beam" class="sidebar-link" data-active={if active_page(assigns) == :beam, do: "true"}>
              <svg class="sidebar-icon" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M11.3 1.046A1 1 0 0112 2v5h4a1 1 0 01.82 1.573l-7 10A1 1 0 018 18v-5H4a1 1 0 01-.82-1.573l7-10a1 1 0 011.12-.38z" clip-rule="evenodd"/></svg>
              BEAM
            </.link>
          </li>
        </ul>
        <div class="sidebar-footer">
          <span class="sidebar-status">
            <span class="sidebar-status-dot"></span>
            <span class="sidebar-status-text">Live</span>
          </span>
        </div>
      </nav>
      <main class="main-content">
        {@inner_content}
      </main>
    </div>
    """
  end

  defp active_page(assigns) do
    case assigns[:live_action] do
      :overview -> :overview
      :sessions -> :sessions
      :beam -> :beam
      _ -> :overview
    end
  end

  defp versioned_asset_path(path, version) when is_binary(path) and is_binary(version) do
    "#{path}?v=#{version}"
  end
end
