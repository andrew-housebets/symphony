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
              params: {_csrf_token: csrfToken}
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
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end

  defp versioned_asset_path(path, version) when is_binary(path) and is_binary(version) do
    "#{path}?v=#{version}"
  end
end
