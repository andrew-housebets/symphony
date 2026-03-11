defmodule SymphonyElixir.Linear.Comment do
  @moduledoc """
  Normalized Linear comment representation used by harness-side workpad logic.
  """

  defstruct [
    :id,
    :body,
    :updated_at,
    :resolved_at
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          body: String.t() | nil,
          updated_at: DateTime.t() | nil,
          resolved_at: DateTime.t() | nil
        }
end
