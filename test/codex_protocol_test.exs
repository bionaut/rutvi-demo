defmodule RutviExercise.CodexProtocolTest do
  use ExUnit.Case, async: true
  alias RutviExercise.Runtime.{CodexProtocol, Schema}
  @final Schema.object(%{"summary" => Schema.string()}, ["summary"])
  def request,
    do: %{
      messages: [%{role: :system, content: "Role instructions"}, %{role: :user, content: "data"}],
      output_schema: @final,
      tools: [%{name: "read_passage"}]
    }

  def envelope(kind, payload),
    do:
      {:ok,
       %{
         output: %{"kind" => kind, "payload_json" => Jason.encode!(payload)},
         model: "gpt-6-luna",
         usage: %{requests: 1}
       }}

  test "transport has a closed required root object without provider schema unions" do
    encoded = CodexProtocol.encode(request())
    schema = encoded.output_schema
    assert schema["type"] == "object"
    assert schema["additionalProperties"] == false
    assert Enum.sort(schema["required"]) == Enum.sort(Map.keys(schema["properties"]))
    refute Map.has_key?(schema, "anyOf")

    assert encoded.messages
           |> hd()
           |> Map.fetch!(:content)
           |> String.contains?(Jason.encode!(@final))

    assert Enum.at(encoded.messages, 1) == Enum.at(request().messages, 1)
  end

  test "final decoding preserves metadata and remains subject to the unchanged application schema" do
    assert {:ok, %{output: valid, model: "gpt-6-luna", usage: %{requests: 1}}} =
             CodexProtocol.decode(envelope("final", %{"summary" => "yes"}))

    assert :ok = Schema.validate(valid, @final)
    assert {:ok, %{output: invalid}} = CodexProtocol.decode(envelope("final", %{"summary" => 42}))
    assert {:error, :validation_error} = Schema.validate(invalid, @final)
  end

  test "tool call structure is checked before exposure to handlers" do
    calls = [
      %{
        "call_id" => "s2",
        "name" => "read_passage",
        "arguments" => %{"source_id" => "S2", "passage_id" => "P1"}
      },
      %{
        "call_id" => "s3",
        "name" => "read_passage",
        "arguments" => %{"source_id" => "S3", "passage_id" => "P1"}
      }
    ]

    assert {:ok, %{tool_calls: ^calls, model: "gpt-6-luna"}} =
             CodexProtocol.decode(envelope("tool_calls", calls))

    for invalid <- [
          [],
          [%{"name" => "read_passage", "arguments" => %{}}],
          [%{"call_id" => "x", "name" => "read_passage", "arguments" => 42}],
          [hd(calls), hd(calls)]
        ] do
      assert {:error, %{code: :invalid_output, retryable: true}} =
               CodexProtocol.decode(envelope("tool_calls", invalid))
    end
  end

  test "malformed envelopes and non-object final values are retryable protocol errors" do
    for value <- [
          %{"kind" => "wrong", "payload_json" => "{}"},
          %{"kind" => "final", "payload_json" => "bad JSON"},
          %{"kind" => "final", "payload_json" => 42},
          %{"kind" => "final", "payload_json" => "[]"},
          %{"kind" => "final", "payload_json" => "{}", "extra" => true}
        ] do
      assert {:error, %{code: :invalid_output, retryable: true}} =
               CodexProtocol.decode({:ok, %{output: value}})
    end
  end
end
