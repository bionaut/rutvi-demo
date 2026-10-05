defmodule Synaptic.SecurityStoreOwner do
  @moduledoc false

  use GenServer

  @prune_interval_ms 60_000
  @tables [
    {:synaptic_audit_store, :bag},
    {:synaptic_tool_result_store, :set},
    {:synaptic_action_controls, :bag},
    {:synaptic_connector_gateway, :bag}
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Enum.each(@tables, fn {name, type} -> ensure_table(name, type) end)
    schedule_prune()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    Synaptic.AuditStore.prune_expired()
    Synaptic.ToolResultStore.prune_expired()
    Synaptic.ActionControls.prune_expired()
    Synaptic.ConnectorGateway.prune_expired()
    schedule_prune()
    {:noreply, state}
  end

  defp ensure_table(name, type) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [
          :named_table,
          :public,
          type,
          read_concurrency: true,
          write_concurrency: true
        ])

      _table ->
        :ok
    end
  end

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_interval_ms)
end
