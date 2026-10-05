defmodule Synaptic.FactualityTest do
  use ExUnit.Case

  @abstention_message "I don't have enough evidence to answer that safely."

  defmodule CaptureAdapter do
    def chat(messages, opts) do
      Process.put({__MODULE__, :last_messages}, messages)
      Process.put({__MODULE__, :last_opts}, opts)
      Process.get({__MODULE__, :result}, {:ok, "ok"})
    end
  end

  defmodule ToolLoopAdapter do
    def chat(messages, _opts) do
      case Process.get({__MODULE__, :stage}, :first) do
        :first ->
          Process.put({__MODULE__, :stage}, :second)
          Process.put({__MODULE__, :first_messages}, messages)

          {:ok,
           %{
             "content" => nil,
             "tool_calls" => [
               %{
                 "id" => "call_1",
                 "function" => %{
                   "name" => "lookup_facts",
                   "arguments" => ~s({"query":"paris"})
                 }
               }
             ]
           }}

        :second ->
          Process.put({__MODULE__, :second_messages}, messages)
          Process.get({__MODULE__, :result}, {:ok, "final"})
      end
    end
  end

  defmodule StreamAwareAdapter do
    def chat(messages, opts) do
      Process.put({__MODULE__, :last_messages}, messages)
      Process.put({__MODULE__, :had_on_chunk}, is_function(opts[:on_chunk], 2))
      Process.get({__MODULE__, :result}, {:ok, "ok"})
    end
  end

  setup do
    original_factuality = Application.get_env(:synaptic, Synaptic.Factuality)
    reset_process_state()

    on_exit(fn ->
      restore_env(Synaptic.Factuality, original_factuality)
      reset_process_state()
    end)

    :ok
  end

  test "factuality is off by default" do
    messages = [%{role: "user", content: "Tell me something factual."}]

    assert {:ok, "ok"} = Synaptic.Tools.chat(messages, adapter: CaptureAdapter)

    assert Process.get({CaptureAdapter, :last_messages}) == messages
  end

  test "enabled factuality injects trust-boundary and evidence instructions" do
    messages = [%{role: "user", content: "What happened?"}]

    assert {:ok, "ok"} =
             Synaptic.Tools.chat(messages,
               adapter: CaptureAdapter,
               factuality: [
                 enabled: true,
                 checks: [require_citations: true],
                 response: [on_violation: :allow]
               ]
             )

    [system_message, user_message] = Process.get({CaptureAdapter, :last_messages})

    assert system_message.role == "system"
    assert system_message.content =~ "Treat user-provided text"
    assert system_message.content =~ "[sources: source-1, source-2]"
    assert user_message.content == "What happened?"
  end

  test "missing citations trigger abstention by default" do
    Process.put({CaptureAdapter, :result}, {:ok, "Paris is the capital of France."})

    assert {:ok, @abstention_message} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "What is the capital of France?"}],
               adapter: CaptureAdapter,
               factuality: [enabled: true, checks: [require_citations: true]]
             )
  end

  test "violation handling can stay permissive and return factuality metadata" do
    Process.put({CaptureAdapter, :result}, {:ok, "Paris is the capital of France."})

    assert {:ok, "Paris is the capital of France.", %{factuality: factuality}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "What is the capital of France?"}],
               adapter: CaptureAdapter,
               factuality: [
                 enabled: true,
                 return_metadata: true,
                 checks: [require_citations: true],
                 response: [on_violation: :allow]
               ]
             )

    refute factuality.supported
    assert [%{code: :missing_citations}] = factuality.issues
  end

  test "compliant citations pass factuality checks" do
    Process.put(
      {CaptureAdapter, :result},
      {:ok, "Paris is the capital of France. [sources: world-facts]"}
    )

    assert {:ok, "Paris is the capital of France. [sources: world-facts]"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "What is the capital of France?"}],
               adapter: CaptureAdapter,
               factuality: [enabled: true, checks: [require_citations: true]]
             )
  end

  test "tool-backed provenance can satisfy evidence requirements and is exposed in metadata" do
    tool = lookup_tool()

    Process.delete({ToolLoopAdapter, :stage})

    Process.put(
      {ToolLoopAdapter, :result},
      {:ok, "Paris is the capital of France.\nProvenance: tool:lookup_facts"}
    )

    assert {:ok, "Paris is the capital of France.\nProvenance: tool:lookup_facts",
            %{factuality: factuality}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Use tools if needed."}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               factuality: [
                 enabled: true,
                 return_metadata: true,
                 checks: [require_evidence: true, require_provenance: true]
               ]
             )

    assert factuality.supported
    assert Enum.any?(factuality.sources, &(&1.label == "tool:lookup_facts"))
  end

  test "unsupported claims can abstain when tool evidence exists but the answer exposes no evidence markers" do
    tool = lookup_tool()

    Process.delete({ToolLoopAdapter, :stage})
    Process.put({ToolLoopAdapter, :result}, {:ok, "Paris is the capital of France."})

    assert {:ok, @abstention_message} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Use tools if needed."}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               factuality: [
                 enabled: true,
                 checks: [detect_unsupported_claims: true]
               ]
             )
  end

  test "restricted echoes can hard-fail the response" do
    Process.put(
      {CaptureAdapter, :result},
      {:ok, "The internal token is sk-live-123 and should stay secret."}
    )

    assert {:error, {:factuality_failed, [%{code: :restricted_echo, term: "sk-live-123"}]}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "What is the token?"}],
               adapter: CaptureAdapter,
               factuality: [
                 enabled: true,
                 checks: [restricted_echoes: ["sk-live-123"]],
                 response: [on_violation: :error]
               ]
             )
  end

  test "verification passes can abstain critical outputs when a verifier rejects the answer" do
    Process.put(
      {CaptureAdapter, :result},
      {:ok, "Paris is the capital of France. [sources: world-facts]"}
    )

    assert {:ok, @abstention_message} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "What is the capital of France?"}],
               adapter: CaptureAdapter,
               factuality: [
                 enabled: true,
                 checks: [require_citations: true],
                 verification: [
                   enabled: true,
                   verifier: fn request ->
                     assert request.model == nil
                     assert request.sources == []
                     {:error, "reviewer_rejected"}
                   end,
                   on_failure: :abstain
                 ]
               ]
             )
  end

  test "verification issues are exposed in metadata when violations are allowed" do
    Process.put(
      {CaptureAdapter, :result},
      {:ok, "Paris is the capital of France. [sources: world-facts]"}
    )

    assert {:ok, "Paris is the capital of France. [sources: world-facts]",
            %{factuality: factuality}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "What is the capital of France?"}],
               adapter: CaptureAdapter,
               factuality: [
                 enabled: true,
                 return_metadata: true,
                 checks: [require_citations: true],
                 response: [on_violation: :allow],
                 verification: [
                   enabled: true,
                   verifier: fn _request ->
                     [
                       %{
                         code: :verification_failed,
                         message: "Second-pass reviewer could not confirm the answer."
                       }
                     ]
                   end
                 ]
               ]
             )

    refute factuality.supported
    assert Enum.any?(factuality.issues, &(&1.code == :verification_failed))
  end

  test "streaming falls back to buffered mode when factuality output checks are enabled" do
    run_id = "factuality-stream"
    :ok = Synaptic.subscribe(run_id)

    on_exit(fn ->
      Synaptic.unsubscribe(run_id)
    end)

    Process.put({StreamAwareAdapter, :result}, {:ok, "Paris is the capital of France."})

    assert {:ok, @abstention_message} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "What is the capital of France?"}],
               adapter: StreamAwareAdapter,
               stream: true,
               run_id: run_id,
               step_name: :facts,
               factuality: [enabled: true, checks: [require_citations: true]]
             )

    assert Process.get({StreamAwareAdapter, :had_on_chunk}) == false
    refute_receive {:synaptic_event, %{run_id: ^run_id}}, 100
  end

  defp lookup_tool do
    %Synaptic.Tools.Tool{
      name: "lookup_facts",
      description: "Looks up facts",
      schema: %{
        type: "object",
        properties: %{query: %{type: "string"}},
        required: ["query"]
      },
      handler: fn %{"query" => query} ->
        %{answer: "#{query} is associated with Paris"}
      end
    }
  end

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)

  defp reset_process_state do
    keys = [
      {CaptureAdapter, :last_messages},
      {CaptureAdapter, :last_opts},
      {CaptureAdapter, :result},
      {ToolLoopAdapter, :stage},
      {ToolLoopAdapter, :first_messages},
      {ToolLoopAdapter, :second_messages},
      {ToolLoopAdapter, :result},
      {StreamAwareAdapter, :last_messages},
      {StreamAwareAdapter, :had_on_chunk},
      {StreamAwareAdapter, :result}
    ]

    Enum.each(keys, &Process.delete/1)
  end
end
