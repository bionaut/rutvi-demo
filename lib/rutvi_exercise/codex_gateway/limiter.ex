defmodule RutviExercise.CodexGateway.Limiter do
  @moduledoc false
  use GenServer

  @active_limit 2
  @queue_limit 4
  @queue_timeout 5_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  def acquire(server \\ __MODULE__), do: GenServer.call(server, :acquire, @queue_timeout + 250)

  def release(owner \\ self(), server \\ __MODULE__),
    do: GenServer.cast(server, {:release, owner})

  @impl true
  def init(:ok),
    do: {:ok, %{active: %{}, monitors: %{}, queue: :queue.new()}}

  @impl true
  def handle_call(:acquire, {owner, _tag}, state)
      when map_size(state.active) < @active_limit do
    monitor = Process.monitor(owner)
    active = Map.put(state.active, owner, monitor)
    monitors = Map.put(state.monitors, monitor, {:active, owner})
    {:reply, :ok, %{state | active: active, monitors: monitors}}
  end

  def handle_call(:acquire, {owner, _tag} = from, state) do
    if :queue.len(state.queue) >= @queue_limit do
      {:reply, {:error, :busy}, state}
    else
      ref = make_ref()
      timer = Process.send_after(self(), {:queue_timeout, ref}, @queue_timeout)
      monitor = Process.monitor(owner)
      entry = {ref, from, owner, timer, monitor}
      queue = :queue.in(entry, state.queue)
      monitors = Map.put(state.monitors, monitor, {:queued, ref})
      {:noreply, %{state | queue: queue, monitors: monitors}}
    end
  end

  @impl true
  def handle_cast({:release, owner}, state), do: {:noreply, free_owner(state, owner)}

  @impl true
  def handle_info({:queue_timeout, ref}, state) do
    case pop_queue_ref(state.queue, ref) do
      {nil, _queue} ->
        {:noreply, state}

      {{_ref, from, _owner, _timer, monitor}, queue} ->
        Process.demonitor(monitor, [:flush])
        GenServer.reply(from, {:error, :busy})
        {:noreply, %{state | queue: queue, monitors: Map.delete(state.monitors, monitor)}}
    end
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    case state.monitors[monitor] do
      {:active, ^owner} ->
        {:noreply, free_owner(%{state | monitors: Map.delete(state.monitors, monitor)}, owner)}

      {:queued, ref} ->
        {_entry, queue} = pop_queue_ref(state.queue, ref)
        {:noreply, %{state | queue: queue, monitors: Map.delete(state.monitors, monitor)}}

      _ ->
        {:noreply, state}
    end
  end

  defp free_owner(state, owner) do
    case Map.pop(state.active, owner) do
      {nil, _active} ->
        state

      {monitor, active} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | active: active, monitors: Map.delete(state.monitors, monitor)}
        grant_next(state)
    end
  end

  defp grant_next(state) do
    case :queue.out(state.queue) do
      {{:value, {_ref, from, owner, timer, queue_monitor}}, queue} ->
        Process.cancel_timer(timer)
        monitors = Map.delete(state.monitors, queue_monitor)
        Process.demonitor(queue_monitor, [:flush])

        if Process.alive?(owner) do
          active_monitor = Process.monitor(owner)
          active = Map.put(state.active, owner, active_monitor)
          monitors = Map.put(monitors, active_monitor, {:active, owner})
          GenServer.reply(from, :ok)
          %{state | active: active, monitors: monitors, queue: queue}
        else
          grant_next(%{state | monitors: monitors, queue: queue})
        end

      {:empty, _queue} ->
        state
    end
  end

  defp pop_queue_ref(queue, ref) do
    {found, kept} =
      queue
      |> :queue.to_list()
      |> Enum.split_with(fn {queued_ref, _from, _owner, _timer, _monitor} ->
        queued_ref == ref
      end)

    {List.first(found), :queue.from_list(kept)}
  end
end
