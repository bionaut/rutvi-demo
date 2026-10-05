defmodule RutviExercise.HTTP.Server do
  @moduledoc """
  Optional supervised HTTP listener for the reference API.
  """

  @default_port 4_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(_opts \\ []) do
    if Application.get_env(:rutvi_exercise, :http_enabled, true) do
      Plug.Cowboy.http(RutviExercise.HTTP.Router, [],
        ip: {0, 0, 0, 0},
        port: port(),
        ref: __MODULE__,
        protocol_options: [request_timeout: 35_000]
      )
    else
      :ignore
    end
  end

  defp port do
    case Integer.parse(System.get_env("HTTP_PORT", Integer.to_string(@default_port))) do
      {port, ""} when port in 1..65_535 -> port
      _ -> raise ArgumentError, "HTTP_PORT must be an integer from 1 to 65535"
    end
  end
end
