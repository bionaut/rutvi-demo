defmodule Synaptic.ToolsTest do
  use ExUnit.Case

  alias Synaptic.MCP.Discovery

  defmodule PrimaryAdapter do
    def chat(_messages, opts), do: {:ok, {:primary, opts}}
  end

  defmodule SecondaryAdapter do
    def chat(_messages, opts), do: {:ok, {:secondary, opts}}
  end

  defmodule ToolAdapter do
    def chat(_messages, _opts) do
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
                   "name" => "echo",
                   "arguments" => ~s<{"text":"hi"}>
                 }
               }
             ]
           }}

        :second ->
          {:ok, "final"}
      end
    end
  end

  defmodule MCPAdapter do
    use Synaptic.MCP.Adapter

    @impl true
    def discover(connection, _opts) do
      Process.put(
        {__MODULE__, :discover_calls},
        Process.get({__MODULE__, :discover_calls}, 0) + 1
      )

      if Keyword.get(connection.adapter_opts, :fail_discovery, false) do
        {:error, :boom}
      else
        {:ok,
         %Discovery{
           tools: [
             %{
               name: Keyword.get(connection.adapter_opts, :remote_tool, "search_issues"),
               description: "Searches issues",
               input_schema:
                 Keyword.get(connection.adapter_opts, :schema, %{
                   type: "object",
                   properties: %{query: %{type: "string"}},
                   required: ["query"]
                 })
             }
           ],
           resources_supported?:
             !Keyword.get(connection.adapter_opts, :resources_unsupported, false),
           resources: nil,
           server_info: %{},
           warnings: []
         }}
      end
    end

    @impl true
    def call_tool(connection, remote_name, args, _opts) do
      Process.put({__MODULE__, :last_call_tool}, {connection.name, remote_name, args})

      if Keyword.get(connection.adapter_opts, :fail_tool_call, false) do
        {:error, :tool_failed}
      else
        {:ok, %{remote: remote_name, args: args}}
      end
    end

    @impl true
    def list_resources(connection, _opts) do
      Process.put({__MODULE__, :last_list_resources}, connection.name)

      {:ok,
       [
         %{
           "uri" => "file:///#{connection.name}/guide.md",
           "name" => "#{connection.name} guide",
           "description" => "Guide"
         }
       ]}
    end

    @impl true
    def read_resource(connection, uri, _opts) do
      Process.put({__MODULE__, :last_read_resource}, {connection.name, uri})
      {:ok, %{"contents" => [%{"text" => "resource:#{connection.name}:#{uri}"}]}}
    end
  end

  defmodule MCPToolLoopAdapter do
    def chat(messages, opts) do
      Process.put(:captured_adapter_tools, opts[:tools] || [])

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
                   "name" => Process.get(:next_tool_name),
                   "arguments" => Process.get(:next_tool_args_json, "{}")
                 }
               }
             ]
           }}

        :second ->
          Process.put(:last_tool_message, List.last(messages))
          {:ok, "final"}
      end
    end
  end

  @messages [%{role: "user", content: "ping"}]

  setup do
    original_tools = Application.get_env(:synaptic, Synaptic.Tools)
    original_mcp = Application.get_env(:synaptic, Synaptic.MCP)

    Application.put_env(:synaptic, Synaptic.Tools,
      llm_adapter: __MODULE__.PrimaryAdapter,
      agents: [
        engineer: [model: "o4-mini", temperature: 0.2],
        translator: [adapter: __MODULE__.SecondaryAdapter, model: "gpt-4o-mini"],
        researcher: [adapter: __MODULE__.PrimaryAdapter, model: "gpt-4o-mini", mcp: [:docs]]
      ]
    )

    Application.put_env(:synaptic, Synaptic.MCP,
      servers: [
        github: [transport: :http, adapter: __MODULE__.MCPAdapter],
        docs: [transport: :http, adapter: __MODULE__.MCPAdapter, remote_tool: "lookup_docs"],
        broken: [transport: :http, adapter: __MODULE__.MCPAdapter, fail_discovery: true]
      ]
    )

    reset_process_state()

    on_exit(fn ->
      restore_env(Synaptic.Tools, original_tools)
      restore_env(Synaptic.MCP, original_mcp)
      reset_process_state()
    end)

    :ok
  end

  test "applies agent defaults" do
    assert {:ok, {:primary, opts}} = Synaptic.Tools.chat(@messages, agent: :engineer)
    assert opts[:model] == "o4-mini"
    assert opts[:temperature] == 0.2
  end

  test "allows explicit overrides" do
    assert {:ok, {:primary, opts}} =
             Synaptic.Tools.chat(@messages, agent: :engineer, temperature: 0.5)

    assert opts[:temperature] == 0.5
  end

  test "uses adapter overrides configured on agent" do
    assert {:ok, {:secondary, opts}} = Synaptic.Tools.chat(@messages, agent: :translator)
    assert opts[:model] == "gpt-4o-mini"
  end

  test "agent defaults can include MCP scope" do
    assert {:ok, {:primary, opts}} = Synaptic.Tools.chat(@messages, agent: :researcher)

    tool_names =
      Enum.map(opts[:tools] || [], fn spec ->
        get_in(spec, [:function, :name])
      end)

    assert "docs__lookup_docs" in tool_names
    refute "github__search_issues" in tool_names
  end

  test "explicit MCP scope overrides the agent default scope" do
    assert {:ok, {:primary, opts}} =
             Synaptic.Tools.chat(@messages,
               agent: :researcher,
               mcp: [:github]
             )

    tool_names =
      Enum.map(opts[:tools] || [], fn spec ->
        get_in(spec, [:function, :name])
      end)

    assert "github__search_issues" in tool_names
    refute "docs__lookup_docs" in tool_names
  end

  test "raises when agent is missing" do
    assert_raise ArgumentError, ~r/unknown Synaptic agent/, fn ->
      Synaptic.Tools.chat(@messages, agent: :missing)
    end
  end

  test "executes tools when adapter requests tool calls" do
    tool = %Synaptic.Tools.Tool{
      name: "echo",
      description: "echoes text",
      schema: %{
        type: "object",
        properties: %{text: %{type: "string"}},
        required: ["text"]
      },
      handler: fn %{"text" => text} ->
        Process.put(:tool_called, text)
        %{reply: text <> "!"}
      end
    }

    Process.delete({ToolAdapter, :stage})

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: ToolAdapter,
               tools: [tool]
             )

    assert Process.get(:tool_called) == "hi"
  end

  test "exposes MCP tools and synthetic resource tools to the adapter" do
    assert {:ok, {:primary, opts}} = Synaptic.Tools.chat(@messages, mcp: [:github])

    names =
      opts[:tools]
      |> Enum.map(&get_in(&1, [:function, :name]))

    assert "github__search_issues" in names
    assert "github__list_resources" in names
    assert "github__read_resource" in names
  end

  test "merges local and MCP tools" do
    tool = %Synaptic.Tools.Tool{
      name: "echo",
      description: "echoes text",
      schema: %{type: "object", properties: %{}},
      handler: fn _args -> "ok" end
    }

    assert {:ok, {:primary, opts}} = Synaptic.Tools.chat(@messages, tools: [tool], mcp: [:github])

    names =
      opts[:tools]
      |> Enum.map(&get_in(&1, [:function, :name]))

    assert "echo" in names
    assert "github__search_issues" in names
  end

  test "discovers MCP capabilities once per top-level chat call" do
    Process.put(:next_tool_name, "github__search_issues")
    Process.put(:next_tool_args_json, ~s({"query":"bugs"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [:github]
             )

    assert Process.get({MCPAdapter, :discover_calls}) == 1
  end

  test "suffixes duplicate normalized server names" do
    connections = [
      %{name: "GitHub", adapter: MCPAdapter, transport: :http},
      %{name: "github", adapter: MCPAdapter, transport: :http}
    ]

    assert {:ok, {:primary, opts}} = Synaptic.Tools.chat(@messages, mcp: connections)

    names =
      opts[:tools]
      |> Enum.map(&get_in(&1, [:function, :name]))

    assert "github__search_issues" in names
    assert "github_2__search_issues" in names
  end

  test "returns an error when local and MCP tool names collide" do
    tool = %Synaptic.Tools.Tool{
      name: "github__search_issues",
      description: "collision",
      schema: %{type: "object", properties: %{}},
      handler: fn _args -> :ok end
    }

    assert {:error, {:duplicate_tool_name, "github__search_issues"}} =
             Synaptic.Tools.chat(@messages, tools: [tool], mcp: [:github])
  end

  test "surfaces which MCP server failed discovery" do
    assert {:error, {:mcp_discovery_failed, "broken", :boom}} =
             Synaptic.Tools.chat(@messages, mcp: [:github, :broken])
  end

  test "dispatches MCP tool calls through the MCP facade" do
    Process.put(:next_tool_name, "github__search_issues")
    Process.put(:next_tool_args_json, ~s({"query":"bugs"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [:github]
             )

    assert {"github", "search_issues", %{"query" => "bugs"}} =
             Process.get({MCPAdapter, :last_call_tool})
  end

  test "reads MCP resources via synthetic tools" do
    Process.put(:next_tool_name, "github__read_resource")
    Process.put(:next_tool_args_json, ~s({"uri":"file:///github/guide.md"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [:github]
             )

    assert {"github", "file:///github/guide.md"} = Process.get({MCPAdapter, :last_read_resource})
    assert "resource:github:file:///github/guide.md" == Process.get(:last_tool_message).content
  end

  test "returns a structured error when synthetic read_resource is missing uri" do
    Process.put(:next_tool_name, "github__read_resource")
    Process.put(:next_tool_args_json, "{}")

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [:github],
               validation: [tools: true]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)
    assert payload["error"] == true
    assert payload["code"] == "invalid_arguments"
    assert payload["tool"] == "read_resource"
  end

  test "returns invalid_arguments for malformed local tool JSON and does not call the handler" do
    tool = %Synaptic.Tools.Tool{
      name: "echo",
      description: "echoes text",
      schema: %{
        type: "object",
        properties: %{text: %{type: "string"}},
        required: ["text"]
      },
      handler: fn _args ->
        Process.put(:local_tool_called, true)
        %{reply: "ok"}
      end
    }

    Process.put(:next_tool_name, "echo")
    Process.put(:next_tool_args_json, ~s({"text":))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               tools: [tool]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)
    assert payload["code"] == "invalid_arguments"

    assert payload["details"] == [
             %{
               "code" => "invalid_json",
               "message" => "Tool arguments must be a valid JSON object.",
               "path" => "#"
             }
           ]

    refute Process.get(:local_tool_called)
  end

  test "returns invalid_arguments for schema-invalid local tool args and does not call the handler" do
    tool = %Synaptic.Tools.Tool{
      name: "echo",
      description: "echoes text",
      schema: %{
        type: "object",
        properties: %{text: %{type: "string"}},
        required: ["text"]
      },
      handler: fn _args ->
        Process.put(:local_tool_called, true)
        %{reply: "ok"}
      end
    }

    Process.put(:next_tool_name, "echo")
    Process.put(:next_tool_args_json, "{}")

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               tools: [tool],
               validation: [tools: true]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)
    assert payload["code"] == "invalid_arguments"
    assert payload["tool"] == "echo"

    assert payload["details"] == [
             %{
               "code" => "missing_required",
               "message" => "Required field \"text\" was not present.",
               "path" => "#/text"
             }
           ]

    refute Process.get(:local_tool_called)
  end

  test "blocks invalid MCP tool arguments before adapter invocation" do
    Process.put(:next_tool_name, "github__search_issues")
    Process.put(:next_tool_args_json, "{}")

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [:github],
               validation: [tools: true]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)
    assert payload["code"] == "invalid_arguments"
    assert payload["server"] == "github"
    assert payload["tool"] == "search_issues"

    assert payload["details"] == [
             %{
               "code" => "missing_required",
               "message" => "Required field \"query\" was not present.",
               "path" => "#/query"
             }
           ]

    refute Process.get({MCPAdapter, :last_call_tool})
  end

  test "synthetic list_resources rejects extra arguments" do
    Process.put(:next_tool_name, "github__list_resources")
    Process.put(:next_tool_args_json, ~s({"unexpected":true}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [:github],
               validation: [tools: true]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)
    assert payload["code"] == "invalid_arguments"
    assert payload["tool"] == "list_resources"

    assert payload["details"] == [
             %{
               "code" => "unexpected_field",
               "message" => "Unexpected field \"unexpected\".",
               "path" => "#/unexpected"
             }
           ]

    refute Process.get({MCPAdapter, :last_list_resources})
  end

  test "fails registry build when a local tool schema is invalid" do
    tool = %Synaptic.Tools.Tool{
      name: "broken",
      description: "broken schema",
      schema: %{type: "object", properties: "oops"},
      handler: fn _args -> :ok end
    }

    assert {:error, {:invalid_tool_schema, "broken", reason}} =
             Synaptic.Tools.chat(@messages, tools: [tool], validation: [tools: true])

    assert reason =~ "schema did not pass validation"
  end

  test "fails registry build when an MCP tool schema is invalid" do
    assert {:error, {:invalid_mcp_tool_schema, "github", "search_issues", reason}} =
             Synaptic.Tools.chat(@messages,
               mcp: [
                 %{
                   name: "github",
                   adapter: MCPAdapter,
                   transport: :http,
                   schema: %{type: "object", properties: "oops"}
                 }
               ],
               validation: [tools: true]
             )

    assert reason =~ "schema did not pass validation"
  end

  test "returns structured MCP tool errors back into the tool loop" do
    Process.put(:next_tool_name, "github__search_issues")
    Process.put(:next_tool_args_json, ~s({"query":"bugs"}))

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [
                 %{name: "github", adapter: MCPAdapter, transport: :http, fail_tool_call: true}
               ]
             )

    payload = Jason.decode!(Process.get(:last_tool_message).content)
    assert payload["error"] == true
    assert payload["code"] == "tool_call_failed"
    assert payload["server"] == "github"
    assert payload["tool"] == "search_issues"
  end

  test "tool schema validation is off by default for local tools" do
    tool = %Synaptic.Tools.Tool{
      name: "broken",
      description: "broken schema",
      schema: %{type: "object", properties: "oops"},
      handler: fn _args -> :ok end
    }

    assert {:ok, {:primary, opts}} = Synaptic.Tools.chat(@messages, tools: [tool])
    assert get_in(hd(opts[:tools]), [:function, :name]) == "broken"
  end

  test "tool argument schema validation is off by default for local tools" do
    tool = %Synaptic.Tools.Tool{
      name: "echo",
      description: "echoes text",
      schema: %{
        type: "object",
        properties: %{text: %{type: "string"}},
        required: ["text"]
      },
      handler: fn args ->
        Process.put(:local_tool_called_with, args)
        %{reply: "ok"}
      end
    }

    Process.put(:next_tool_name, "echo")
    Process.put(:next_tool_args_json, "{}")

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               tools: [tool]
             )

    assert Process.get(:local_tool_called_with) == %{}
  end

  test "tool argument schema validation is off by default for MCP tools" do
    Process.put(:next_tool_name, "github__search_issues")
    Process.put(:next_tool_args_json, "{}")

    assert {:ok, "final"} =
             Synaptic.Tools.chat(@messages,
               adapter: MCPToolLoopAdapter,
               mcp: [:github]
             )

    assert {"github", "search_issues", %{}} = Process.get({MCPAdapter, :last_call_tool})
  end

  test "falls back to non-streaming when MCP tools are present" do
    assert {:ok, {:primary, opts}} =
             Synaptic.Tools.chat(@messages, stream: true, mcp: [:github])

    refute opts[:stream]
    assert is_list(opts[:tools])
    assert Process.get({MCPAdapter, :discover_calls}) == 1
  end

  test "sanitizes top-level MCP combinators for OpenAI tool schemas" do
    schema = %{
      "type" => "object",
      "oneOf" => [
        %{
          "type" => "object",
          "properties" => %{
            "selector" => %{"type" => "string"},
            "index" => %{"type" => "integer"}
          },
          "required" => ["selector"]
        }
      ]
    }

    assert {:ok, {:primary, opts}} =
             Synaptic.Tools.chat(@messages,
               mcp: [
                 %{name: "browser_use", adapter: MCPAdapter, transport: :http, schema: schema}
               ]
             )

    parameters =
      opts[:tools]
      |> Enum.find(&(get_in(&1, [:function, :name]) == "browser_use__search_issues"))
      |> get_in([:function, :parameters])

    assert parameters["type"] == "object"
    refute Map.has_key?(parameters, "oneOf")
    refute Map.has_key?(parameters, "anyOf")
    refute Map.has_key?(parameters, "allOf")
    refute Map.has_key?(parameters, "enum")
    refute Map.has_key?(parameters, "not")
    assert Map.has_key?(parameters["properties"], "selector")
  end

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)

  defp reset_process_state do
    keys = [
      {ToolAdapter, :stage},
      {MCPAdapter, :discover_calls},
      {MCPAdapter, :last_call_tool},
      {MCPAdapter, :last_list_resources},
      {MCPAdapter, :last_read_resource},
      {MCPToolLoopAdapter, :stage},
      :captured_adapter_tools,
      :local_tool_called,
      :last_tool_message,
      :next_tool_name,
      :next_tool_args_json,
      :tool_called
    ]

    Enum.each(keys, &Process.delete/1)
  end
end
