defmodule RutviExercise.Models.RemoteCodexTest do
  use ExUnit.Case, async: false

  alias RutviExercise.Models.RemoteCodex

  @token String.duplicate("a", 64)
  @schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "string"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  setup do
    System.put_env("RUTVI_CODEX_GATEWAY_URL", "http://127.0.0.1:4041")
    # `kubectl create secret --from-file` preserves the token file's final newline.
    System.put_env("RUTVI_CODEX_GATEWAY_TOKEN", @token <> "\n")

    on_exit(fn ->
      System.delete_env("RUTVI_CODEX_GATEWAY_URL")
      System.delete_env("RUTVI_CODEX_GATEWAY_TOKEN")
    end)

    :ok
  end

  test "sends only the structured request over authenticated gateway and checks fixed Sol metadata" do
    parent = self()

    client = fn :post, {url, headers, content_type, body}, request_opts, _http_opts ->
      send(parent, {:request, url, headers, content_type, Jason.decode!(body), request_opts})

      response = %{
        output: %{"answer" => "ready"},
        model: "gpt-6.1-sol",
        reasoning_effort: "medium",
        usage: %{prompt_tokens: 8, completion_tokens: 2, total_tokens: 10}
      }

      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], Jason.encode!(response)}}
    end

    assert {:ok, result} =
             RemoteCodex.generate(
               %{
                 messages: [%{role: :user, content: "Return a tiny JSON response."}],
                 output_schema: @schema,
                 command: "must never be forwarded"
               },
               timeout_ms: 90_000,
               http_client: client
             )

    assert result.output == %{"answer" => "ready"}
    assert result.model == "gpt-6.1-sol"
    assert result.reasoning_effort == "medium"

    assert_received {:request, ~c"http://127.0.0.1:4041/v1/generate", headers,
                     ~c"application/json", body, opts}

    {~c"authorization", authorization} = List.keyfind(headers, ~c"authorization", 0)
    assert String.starts_with?(List.to_string(authorization), "Bearer ")
    refute String.contains?(List.to_string(authorization), "\n")
    assert map_size(body) == 2
    assert Map.has_key?(body, "messages")
    assert Map.has_key?(body, "output_schema")
    assert opts[:timeout] == 95_000
  end

  test "rejects model drift and maps structured errors without fallback" do
    request = %{messages: [%{role: :user, content: "x"}], output_schema: @schema}

    for {model, effort} <- [
          {"gpt-5.5", "medium"},
          {"gpt-6-luna", "low"},
          {"gpt-6.1-sol", "low"},
          {"gpt-6.1-sol", "high"}
        ] do
      client = fn _method, _request, _request_opts, _http_opts ->
        body =
          Jason.encode!(%{output: %{"answer" => "x"}, model: model, reasoning_effort: effort})

        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], body}}
      end

      assert {:error, %{code: :gateway_protocol_error}} =
               RemoteCodex.generate(request, http_client: client)
    end

    error_client = fn _method, _request, _request_opts, _http_opts ->
      body =
        Jason.encode!(%{
          error: %{code: "model_unavailable", message: "Sol unavailable", retryable: false}
        })

      {:ok, {{~c"HTTP/1.1", 503, ~c"Unavailable"}, [], body}}
    end

    assert {:error, %{code: :model_unavailable, retryable: false}} =
             RemoteCodex.generate(request, http_client: error_client)
  end

  test "rejects unsafe request additions and oversized timeouts before transport" do
    request = %{messages: [%{role: :user, content: "x"}], output_schema: @schema}
    client = fn _method, _request, _request_opts, _http_opts -> flunk("must not send") end

    assert {:error, %{code: :invalid_options}} =
             RemoteCodex.generate(request, timeout_ms: 120_001, http_client: client)

    assert {:error, %{code: :invalid_request}} =
             RemoteCodex.generate(%{prompt: "x", output_schema: @schema}, http_client: client)
  end
end
