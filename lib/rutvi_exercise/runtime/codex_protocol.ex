defmodule RutviExercise.Runtime.CodexProtocol do
  @moduledoc """
  Provider-compatible transport for arbitrary application schemas.

  Codex receives a closed root object containing a discriminator and JSON text.
  The decoded final value still passes the original application schema; decoded
  tool calls pass the protocol schema before any application handler is considered.
  """
  alias RutviExercise.Runtime.Schema

  def envelope_schema do
    Schema.object(
      %{
        "kind" => %{"type" => "string", "enum" => ["final", "tool_calls"]},
        "payload_json" => %{"type" => "string"}
      },
      ["kind", "payload_json"]
    )
  end

  def encode(request) do
    final_example = %{
      "kind" => "final",
      "payload_json" => Jason.encode!(example(request.output_schema))
    }

    tool_example = %{
      "kind" => "tool_calls",
      "payload_json" =>
        Jason.encode!([
          %{
            "call_id" => "read-s1",
            "name" => "read_passage",
            "arguments" => %{"source_id" => "S1", "passage_id" => "P1"}
          }
        ])
    }

    instructions = """
    Transport protocol: return exactly an object with kind and payload_json.
    kind is "final" or "tool_calls". payload_json is a STRING containing valid JSON,
    with quotation marks escaped as required by the surrounding JSON object.
    For kind="final", encode the complete final OBJECT in payload_json. That decoded
    object must satisfy this application JSON schema: #{Jason.encode!(request.output_schema)}
    For kind="tool_calls", encode a nonempty ARRAY of objects in payload_json. Each
    object has a unique nonempty string call_id, a nonempty string name, and an
    arguments OBJECT. Use only available_tools. Tool results appear in later messages.
    Do not mix final content and tool calls. If no tool is needed, return kind="final".
    Final-envelope STRUCTURE example (replace placeholders with your actual answer): #{Jason.encode!(final_example)}
    Tool-envelope STRUCTURE example (only use a tool if it is available): #{Jason.encode!(tool_example)}
    The outer object has ONLY kind and payload_json. Inside final payload_json,
    the root is the application object, without another output/result/final wrapper.
    Never put the final answer in a tool call. After tool results, return the final
    application object when all requested passages have been read.
    """

    request
    |> Map.put(:output_schema, envelope_schema())
    |> Map.update!(:messages, fn [system | rest] ->
      [%{system | content: system.content <> "\n" <> instructions} | rest]
    end)
  end

  defp example(%{"enum" => [first | _]}), do: first

  defp example(%{"type" => "object", "properties" => properties}),
    do: Map.new(properties, fn {key, schema} -> {key, example(schema)} end)

  defp example(%{"type" => "array", "items" => items} = schema),
    do: List.duplicate(example(items), schema["minItems"] || 1)

  defp example(%{"type" => "integer"}), do: 0
  defp example(%{"type" => "boolean"}), do: false
  defp example(_), do: "replace with actual content"

  def decode({:ok, %{output: envelope} = response}) do
    with :ok <- Schema.validate(envelope, envelope_schema()),
         {:ok, payload} <- Jason.decode(envelope["payload_json"]) do
      case {envelope["kind"], payload} do
        {"final", output} when is_map(output) ->
          {:ok, Map.put(response, :output, output)}

        {"tool_calls", calls} when is_list(calls) and calls != [] ->
          if valid_calls?(calls) do
            {:ok, response |> Map.delete(:output) |> Map.put(:tool_calls, calls)}
          else
            invalid()
          end

        _ ->
          invalid()
      end
    else
      _ -> invalid()
    end
  end

  def decode({:error, _} = error), do: error
  def decode(_), do: invalid()

  defp valid_calls?(calls) do
    call_schema =
      Schema.object(
        %{
          "call_id" => Schema.string(),
          "name" => Schema.string(),
          "arguments" => %{"type" => "object"}
        },
        ["call_id", "name", "arguments"]
      )

    Enum.all?(calls, &(Schema.validate(&1, call_schema) == :ok)) and
      length(Enum.uniq_by(calls, & &1["call_id"])) == length(calls)
  end

  defp invalid,
    do:
      {:error,
       %{
         code: :invalid_output,
         message: "Invalid Codex transport envelope or decoded payload.",
         retryable: true
       }}
end
