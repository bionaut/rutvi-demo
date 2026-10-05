defmodule RutviExercise.Models.CodexTest do
  use ExUnit.Case, async: true

  alias RutviExercise.Models.Codex

  @schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "string"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  test "uses bounded local Codex settings and validates structured output" do
    parent = self()
    scratch = scratch_dir()

    command_runner = fn bin, args, command_opts ->
      schema_path = flag_value(args, "--output-schema")
      send(parent, {:invoked, bin, args, command_opts, File.read!(schema_path)})

      event = %{
        "type" => "item.completed",
        "item" => %{"type" => "agent_message", "text" => ~s({"answer":"ready"})}
      }

      usage = %{
        "type" => "turn.completed",
        "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
      }

      {Jason.encode!(event) <> "\n" <> Jason.encode!(usage), 0}
    end

    assert {:ok, result} =
             Codex.generate(
               %{
                 prompt: "Return one short answer.",
                 output_schema: @schema
               },
               command_runner: command_runner,
               codex_bin: "/bin/echo",
               cwd: scratch,
               scratch_dir: scratch
             )

    assert result == %{
             output: %{"answer" => "ready"},
             model: "gpt-6.1-sol",
             reasoning_effort: "medium",
             usage: %{
               prompt_tokens: 4,
               completion_tokens: 2,
               total_tokens: 6,
               cached_input_tokens: 0,
               reasoning_output_tokens: 0
             }
           }

    assert_received {:invoked, "/bin/echo", args, command_opts, schema_json}
    assert flag_value(args, "--ask-for-approval") == "never"
    assert flag_value(args, "--model") == "gpt-6.1-sol"
    assert flag_value(args, "--sandbox") == "read-only"
    assert flag_value(args, "-c") == ~s(model_reasoning_effort="medium")
    assert flag_value(args, "-C") == scratch
    assert "--ephemeral" in args
    assert "--ignore-user-config" in args
    assert "--skip-git-repo-check" in args
    refute "--add-dir" in args
    refute "--dangerously-bypass-approvals-and-sandbox" in args
    assert command_opts[:cd] == scratch
    assert {"OPENAI_API_KEY", nil} in command_opts[:env]
    assert {"CODEX_API_KEY", nil} in command_opts[:env]
    assert Jason.decode!(schema_json) == @schema
    refute Enum.any?(File.ls!(scratch), &String.starts_with?(&1, "output-schema-"))
  end

  test "supports message lists with the requested output schema" do
    parent = self()

    command_runner = fn _bin, args, _opts ->
      send(parent, {:prompt, List.last(args)})
      {agent_message(~s({"answer":"ok"})), 0}
    end

    assert {:ok, %{output: %{"answer" => "ok"}}} =
             Codex.generate(
               %{
                 messages: [
                   %{role: :system, content: "Return JSON."},
                   %{role: :user, content: "Say ok."}
                 ],
                 output_schema: @schema
               },
               command_runner: command_runner,
               codex_bin: "/bin/echo",
               scratch_dir: scratch_dir()
             )

    assert_received {:prompt, prompt}
    assert prompt =~ "[SYSTEM]\nReturn JSON."
    assert prompt =~ "[USER]\nSay ok."
  end

  test "rejects invalid requests and schemas before invoking Codex" do
    command_runner = fn _bin, _args, _opts -> flunk("Codex must not run") end

    assert {:error, %{code: :invalid_options, retryable: false}} =
             Codex.generate(%{prompt: "hi", output_schema: @schema}, timeout_ms: 130_000)

    assert {:error, %{code: :invalid_output_schema}} =
             Codex.generate(
               %{prompt: "hi", output_schema: %{"type" => "not-a-json-schema-type"}},
               command_runner: command_runner
             )

    assert {:error, %{code: :invalid_request}} =
             Codex.generate(
               %{prompt: "", output_schema: @schema},
               command_runner: command_runner
             )
  end

  test "rejects model output that fails local schema validation" do
    command_runner = fn _bin, _args, _opts -> {agent_message(~s({"answer":42})), 0} end

    assert {:error, %{code: :schema_validation_failed, retryable: true}} =
             Codex.generate(
               %{prompt: "Return the wrong type.", output_schema: @schema},
               command_runner: command_runner,
               codex_bin: "/bin/echo",
               scratch_dir: scratch_dir()
             )
  end

  test "classifies the CLI's explicit model rejection accurately" do
    error = %{
      "type" => "error",
      "status" => 400,
      "error" => %{
        "type" => "invalid_request_error",
        "message" =>
          "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."
      }
    }

    command_runner = fn _bin, _args, _opts -> {Jason.encode!(error), 1} end

    assert {:error,
            %{
              code: :provider_error,
              retryable: false,
              details: %{
                exit_status: 1,
                failure_class: :model_unavailable
              }
            }} =
             Codex.generate(
               %{prompt: "Return JSON.", output_schema: @schema},
               command_runner: command_runner,
               codex_bin: "/bin/echo",
               scratch_dir: scratch_dir()
             )
  end

  test "accepts a oneOf schema with object variants for final output and tool calls" do
    schema = %{
      "oneOf" => [
        %{
          "type" => "object",
          "properties" => %{"answer" => %{"type" => "string"}},
          "required" => ["answer"],
          "additionalProperties" => false
        },
        %{
          "type" => "object",
          "properties" => %{
            "tool_calls" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "name" => %{"type" => "string"},
                  "arguments" => %{"type" => "object"}
                },
                "required" => ["name", "arguments"],
                "additionalProperties" => false
              }
            }
          },
          "required" => ["tool_calls"],
          "additionalProperties" => false
        }
      ]
    }

    command_runner = fn _bin, _args, _opts ->
      {agent_message(~s({"tool_calls":[{"name":"read_passage","arguments":{"source_id":"S1"}}]})),
       0}
    end

    assert {:ok, %{output: %{"tool_calls" => [%{"name" => "read_passage"}]}}} =
             Codex.generate(
               %{prompt: "Request one read_passage tool call.", output_schema: schema},
               command_runner: command_runner,
               codex_bin: "/bin/echo",
               scratch_dir: scratch_dir()
             )
  end

  test "normalizes provider failure without exposing CLI output" do
    command_runner = fn _bin, _args, _opts -> {"sensitive provider output", 1} end

    assert {:error,
            %{
              code: :provider_error,
              retryable: false,
              details: %{reason_type: :codex_exec_failed}
            }} =
             Codex.generate(
               %{prompt: "Return JSON.", output_schema: @schema},
               command_runner: command_runner,
               codex_bin: "/bin/echo",
               scratch_dir: scratch_dir()
             )
  end

  defp agent_message(text) do
    Jason.encode!(%{
      "type" => "item.completed",
      "item" => %{"type" => "agent_message", "text" => text}
    })
  end

  defp scratch_dir do
    dir = Path.join(System.tmp_dir!(), "rutvi-codex-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp flag_value(args, flag) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^flag, value] -> value
      _ -> nil
    end)
  end
end
