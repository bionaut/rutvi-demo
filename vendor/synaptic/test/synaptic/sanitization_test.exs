defmodule Synaptic.SanitizationTest do
  use ExUnit.Case

  defmodule CaptureAdapter do
    def chat(messages, _opts) do
      Process.put({__MODULE__, :last_messages}, messages)
      {:ok, "ok"}
    end
  end

  defmodule ToolLoopAdapter do
    def chat(messages, _opts) do
      case Process.get({__MODULE__, :stage}, :first) do
        :first ->
          Process.put({__MODULE__, :stage}, :second)

          {:ok,
           %{
             "content" => nil,
             "tool_calls" => [
               %{
                 "id" => "call_1",
                 "function" => %{
                   "name" => "dangerous_tool",
                   "arguments" =>
                     ~s|{"website":"javascript:alert(1)","file_name":"../../etc/passwd","command":"echo hi && rm -rf /","markup":"<b>Hello</b>"}|
                 }
               }
             ]
           }}

        :second ->
          Process.put(:sanitized_tool_message, List.last(messages))
          {:ok, "final"}
      end
    end
  end

  setup do
    original = Application.get_env(:synaptic, Synaptic.Sanitization)
    reset_process_state()

    on_exit(fn ->
      restore_env(Synaptic.Sanitization, original)
      reset_process_state()
    end)

    :ok
  end

  test "sanitization is off by default" do
    messages = [%{role: "user", content: "<b>Hello</b> [portal](https://example.com)"}]

    assert {:ok, "ok"} = Synaptic.Tools.chat(messages, adapter: CaptureAdapter)

    captured = Enum.at(Process.get({CaptureAdapter, :last_messages}), 0).content
    assert captured == "<b>Hello</b> [portal](https://example.com)"
  end

  test "prompt sanitization strips html and neutralizes markdown when enabled" do
    messages = [
      %{
        role: "user",
        content: "<script>alert(1)</script><b>Hello</b> [portal](https://example.com) **now**"
      }
    ]

    assert {:ok, "ok"} =
             Synaptic.Tools.chat(messages,
               adapter: CaptureAdapter,
               sanitization: [enabled: true]
             )

    captured = Enum.at(Process.get({CaptureAdapter, :last_messages}), 0).content

    refute captured =~ "<script>"
    refute captured =~ "<b>"
    refute captured =~ "https://example.com"
    assert captured == "Hello portal now"
  end

  test "per-call sanitization false overrides global sanitization config" do
    Application.put_env(:synaptic, Synaptic.Sanitization, enabled: true)

    messages = [%{role: "user", content: "<b>Hello</b> [portal](https://example.com)"}]

    assert {:ok, "ok"} =
             Synaptic.Tools.chat(messages,
               adapter: CaptureAdapter,
               sanitization: false
             )

    captured = Enum.at(Process.get({CaptureAdapter, :last_messages}), 0).content
    assert captured == "<b>Hello</b> [portal](https://example.com)"
  end

  test "tool argument sanitization rewrites dangerous url, filename, shell, and html fields" do
    tool = %Synaptic.Tools.Tool{
      name: "dangerous_tool",
      description: "Runs a dangerous tool",
      schema: %{
        type: "object",
        properties: %{
          website: %{type: "string"},
          file_name: %{type: "string"},
          command: %{type: "string"},
          markup: %{type: "string"}
        },
        required: ["website", "file_name", "command", "markup"]
      },
      handler: fn args ->
        Process.put(:sanitized_tool_args, args)
        %{ok: true}
      end
    }

    Process.delete({ToolLoopAdapter, :stage})

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Run it"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               sanitization: [
                 enabled: true,
                 tools: [
                   field_types: %{
                     website: :url,
                     file_name: :filename,
                     command: :shell,
                     markup: :html
                   }
                 ]
               ]
             )

    assert Process.get(:sanitized_tool_args) == %{
             "website" => "",
             "file_name" => "passwd",
             "command" => "echo hi rm -rf /",
             "markup" => "Hello"
           }
  end

  test "tool result sanitization cleans dangerous content before prompt reuse" do
    tool = %Synaptic.Tools.Tool{
      name: "dangerous_tool",
      description: "Runs a dangerous tool",
      schema: %{
        type: "object",
        properties: %{website: %{type: "string"}},
        required: ["website"]
      },
      handler: fn _args ->
        %{
          html: "<b>Hello</b>",
          markdown: "[portal](https://example.com)",
          note: "safe"
        }
      end
    }

    Process.delete({ToolLoopAdapter, :stage})

    assert {:ok, "final"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Run it"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               sanitization: [
                 enabled: true,
                 tool_results: [
                   enabled: true,
                   field_types: %{html: :html, markdown: :markdown}
                 ]
               ]
             )

    tool_message = Process.get(:sanitized_tool_message)
    decoded = Jason.decode!(tool_message.content)

    assert decoded["html"] == "Hello"
    assert decoded["markdown"] == "portal"
    assert decoded["note"] == "safe"
  end

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)

  defp reset_process_state do
    keys = [
      {CaptureAdapter, :last_messages},
      {ToolLoopAdapter, :stage},
      :sanitized_tool_args,
      :sanitized_tool_message
    ]

    Enum.each(keys, &Process.delete/1)
  end
end
