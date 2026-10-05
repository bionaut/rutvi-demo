defmodule RutviExercise.HTTP.Auth do
  @moduledoc false

  @demo_enabled Mix.env() in [:dev, :test]

  @demo_identities %{
    "dev-token-a-user-1" => %{namespace_id: "A", user_id: "u1", session_id: "s1"},
    "dev-token-a-user-2" => %{namespace_id: "A", user_id: "u2", session_id: "s1"},
    "dev-token-b-user-1" => %{namespace_id: "B", user_id: "u1", session_id: "s1"}
  }

  @doc "Resolves a bearer token to server-controlled caller scope."
  def caller(conn) do
    case bearer(conn) do
      nil -> {:error, :unauthorized}
      token -> lookup(token)
    end
  end

  defp bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [<<"Bearer ", token::binary>>] when byte_size(token) > 0 -> token
      _ -> nil
    end
  end

  defp lookup(token) do
    case identities() do
      {:ok, identities} ->
        match =
          Enum.find(identities, fn {candidate, _caller} ->
            secure_equal?(candidate, token)
          end)

        case match do
          {_token, caller} -> {:ok, caller}
          nil -> {:error, :unauthorized}
        end

      :missing ->
        {:error, :authentication_not_configured}
    end
  end

  defp identities do
    configured =
      Application.get_env(:rutvi_exercise, :http_identities) ||
        System.get_env("HTTP_IDENTITIES")

    cond do
      is_map(configured) -> validate_identities(configured)
      is_binary(configured) -> decode_identities(configured)
      true -> if @demo_enabled, do: {:ok, @demo_identities}, else: :missing
    end
  end

  defp decode_identities(value) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(value),
         {:ok, identities} <- normalize_identities(decoded) do
      {:ok, identities}
    else
      _ -> {:error, :invalid_identity_configuration}
    end
  end

  defp validate_identities(identities), do: normalize_identities(identities)

  defp normalize_identities(identities) do
    normalized =
      Enum.reduce_while(identities, %{}, fn {token, caller}, acc ->
        with true <- is_binary(token) and byte_size(token) >= 16,
             true <- is_map(caller),
             namespace when is_binary(namespace) and namespace != "" <-
               field(caller, :namespace_id),
             user when is_binary(user) and user != "" <- field(caller, :user_id),
             session when is_binary(session) and session != "" <- field(caller, :session_id) do
          value = %{namespace_id: namespace, user_id: user, session_id: session}
          {:cont, Map.put(acc, token, value)}
        else
          _ -> {:halt, :invalid}
        end
      end)

    if normalized == :invalid or map_size(normalized) == 0 do
      {:error, :invalid_identity_configuration}
    else
      {:ok, normalized}
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_left, _right), do: false
end
