defmodule Synaptic.PrivacyTest do
  use ExUnit.Case

  defmodule CaptureAdapter do
    def chat(messages, opts) do
      Process.put({__MODULE__, :last_messages}, messages)
      Process.put({__MODULE__, :last_opts}, opts)
      Process.get({__MODULE__, :result}, {:ok, "ok"})
    end
  end

  defmodule PrivacyToolLoopAdapter do
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
                   "name" => "send_email",
                   "arguments" => ~s({"email":"[PII_EMAIL_1]"})
                 }
               }
             ]
           }}

        :second ->
          Process.put({__MODULE__, :second_messages}, messages)
          {:ok, "final"}
      end
    end
  end

  defmodule StreamPrivacyAdapter do
    def chat(messages, opts) do
      Process.put({__MODULE__, :last_messages}, messages)

      if on_chunk = opts[:on_chunk] do
        on_chunk.("Contact jane@example.com", "Contact jane@example.com")
      end

      {:ok, "Contact jane@example.com"}
    end
  end

  setup do
    original_privacy = Application.get_env(:synaptic, Synaptic.Privacy)
    reset_process_state()

    on_exit(fn ->
      restore_env(Synaptic.Privacy, original_privacy)
      reset_process_state()
    end)

    :ok
  end

  test "privacy is off by default" do
    messages = [%{role: "user", content: "Reach jane@example.com"}]

    assert {:ok, "ok"} = Synaptic.Tools.chat(messages, adapter: CaptureAdapter)

    captured = Process.get({CaptureAdapter, :last_messages})
    assert Enum.at(captured, 0).content == "Reach jane@example.com"
  end

  test "prompt privacy tokenizes common PII when enabled" do
    messages = [%{role: "user", content: "Reach jane@example.com or +1 (415) 555-2671"}]

    assert {:ok, "ok"} =
             Synaptic.Tools.chat(messages,
               adapter: CaptureAdapter,
               privacy: [enabled: true]
             )

    captured_content = Enum.at(Process.get({CaptureAdapter, :last_messages}), 0).content

    refute captured_content =~ "jane@example.com"
    refute captured_content =~ "+1 (415) 555-2671"
    assert captured_content =~ "[PII_EMAIL_1]"
    assert captured_content =~ "[PII_PHONE_1]"
  end

  test "per-call privacy false overrides global privacy config" do
    Application.put_env(:synaptic, Synaptic.Privacy, enabled: true)
    messages = [%{role: "user", content: "Reach jane@example.com"}]

    assert {:ok, "ok"} =
             Synaptic.Tools.chat(messages,
               adapter: CaptureAdapter,
               privacy: false
             )

    captured = Enum.at(Process.get({CaptureAdapter, :last_messages}), 0).content
    assert captured == "Reach jane@example.com"
  end

  test "global privacy config enables prompt filtering without per-call opts" do
    Application.put_env(:synaptic, Synaptic.Privacy, enabled: true)
    messages = [%{role: "user", content: "Reach jane@example.com"}]

    assert {:ok, "ok"} = Synaptic.Tools.chat(messages, adapter: CaptureAdapter)

    captured = Enum.at(Process.get({CaptureAdapter, :last_messages}), 0).content
    refute captured =~ "jane@example.com"
    assert captured =~ "[PII_EMAIL_1]"
  end

  test "field-level prompt actions can allow specific structured values" do
    messages = [
      %{
        role: "user",
        content: %{
          email: "jane@example.com",
          phone: "+1 (415) 555-2671"
        }
      }
    ]

    assert {:ok, "ok"} =
             Synaptic.Tools.chat(messages,
               adapter: CaptureAdapter,
               privacy: [
                 enabled: true,
                 prompt: [field_actions: %{email: :allow}]
               ]
             )

    captured = Enum.at(Process.get({CaptureAdapter, :last_messages}), 0).content

    assert captured.email == "jane@example.com"
    assert captured.phone == "[PII_PHONE_1]"
  end

  test "prompt derived facts mode sends classifications instead of raw structured PII" do
    messages = [
      %{
        role: "user",
        content: %{
          email: "jane@example.com",
          phone: "+1 (415) 555-2671"
        }
      }
    ]

    assert {:ok, "ok"} =
             Synaptic.Tools.chat(messages,
               adapter: CaptureAdapter,
               privacy: [enabled: true, prompt: [derived_facts: true]]
             )

    captured = Enum.at(Process.get({CaptureAdapter, :last_messages}), 0).content

    assert captured["email_present"] == true
    assert captured["email_valid"] == true
    assert captured["email_type"] == "email"
    assert captured["email_sensitivity"] == "pii"
    assert captured["phone_present"] == true
    assert captured["phone_valid"] == true
    refute Map.has_key?(captured, :email)
    refute Map.has_key?(captured, "email")
  end

  test "output privacy masks raw PII by default" do
    Process.put({CaptureAdapter, :result}, {:ok, "Send it to jane@example.com"})

    assert {:ok, result} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "who?"}],
               adapter: CaptureAdapter,
               privacy: [enabled: true]
             )

    assert result == "Send it to j***@example.com"
  end

  test "output rehydration is optional and controlled by policy" do
    messages = [%{role: "user", content: "Reach jane@example.com"}]
    Process.put({CaptureAdapter, :result}, {:ok, "Use [PII_EMAIL_1] for follow-up"})

    assert {:ok, "Use [PII_EMAIL_1] for follow-up"} =
             Synaptic.Tools.chat(messages,
               adapter: CaptureAdapter,
               privacy: [enabled: true]
             )

    assert {:ok, "Use jane@example.com for follow-up"} =
             Synaptic.Tools.chat(messages,
               adapter: CaptureAdapter,
               privacy: [enabled: true, output: [rehydrate: true]]
             )
  end

  test "privacy metadata exposes sensitivity levels and provenance when enabled" do
    Process.put({CaptureAdapter, :result}, {:ok, "Reply to jane@example.com"})

    assert {:ok, "Reply to j***@example.com", %{privacy: privacy}} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Reach jane@example.com"}],
               adapter: CaptureAdapter,
               privacy: [enabled: true, return_metadata: true]
             )

    assert privacy.detection_count >= 2
    assert :pii in privacy.sensitivity_levels
    assert :user_provided in privacy.provenance
    assert :model_generated in privacy.provenance

    assert Enum.any?(privacy.detections, fn detection ->
             detection.type == :email and detection.sensitivity == :pii and
               detection.provenance in [:user_provided, :model_generated]
           end)
  end

  test "tool arguments are rehydrated outside the model boundary and tool results are sanitized on the way back" do
    tool = %Synaptic.Tools.Tool{
      name: "send_email",
      description: "sends an email",
      schema: %{
        type: "object",
        properties: %{email: %{type: "string"}},
        required: ["email"]
      },
      handler: fn %{"email" => email} ->
        Process.put(:tool_email_arg, email)
        %{status: "sent to #{email}"}
      end
    }

    Process.delete({PrivacyToolLoopAdapter, :stage})

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Please email jane@example.com"}],
               adapter: PrivacyToolLoopAdapter,
               tools: [tool],
               privacy: [enabled: true]
             )

    assert Process.get(:tool_email_arg) == "jane@example.com"

    first_messages = Process.get({PrivacyToolLoopAdapter, :first_messages})
    assert Enum.at(first_messages, 0).content =~ "[PII_EMAIL_1]"

    second_messages = Process.get({PrivacyToolLoopAdapter, :second_messages})
    tool_message = List.last(second_messages)

    refute tool_message.content =~ "jane@example.com"
    assert tool_message.content =~ "[PII_EMAIL_1]"
  end

  test "streamed output is filtered before PubSub events are emitted" do
    run_id = "privacy-stream"
    :ok = Synaptic.subscribe(run_id)

    on_exit(fn ->
      Synaptic.unsubscribe(run_id)
    end)

    assert {:ok, "Contact j***@example.com"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "hello"}],
               adapter: StreamPrivacyAdapter,
               stream: true,
               run_id: run_id,
               step_name: :privacy_step,
               privacy: [enabled: true]
             )

    assert_receive {:synaptic_event,
                    %{
                      event: :stream_chunk,
                      chunk: chunk,
                      accumulated: accumulated,
                      run_id: ^run_id
                    }},
                   1_000

    refute chunk =~ "jane@example.com"
    refute accumulated =~ "jane@example.com"
    assert chunk =~ "j***@example.com"
    assert accumulated =~ "j***@example.com"

    assert_receive {:synaptic_event,
                    %{event: :stream_done, accumulated: done_accumulated, run_id: ^run_id}},
                   1_000

    refute done_accumulated =~ "jane@example.com"
    assert done_accumulated =~ "j***@example.com"
  end

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)

  defp reset_process_state do
    keys = [
      {CaptureAdapter, :last_messages},
      {CaptureAdapter, :last_opts},
      {CaptureAdapter, :result},
      {PrivacyToolLoopAdapter, :first_messages},
      {PrivacyToolLoopAdapter, :second_messages},
      {PrivacyToolLoopAdapter, :stage},
      {StreamPrivacyAdapter, :last_messages},
      :tool_email_arg
    ]

    Enum.each(keys, &Process.delete/1)
  end
end
