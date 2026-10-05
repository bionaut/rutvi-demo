defmodule RutviExercise.Store do
  @moduledoc "Single-replica durable transaction boundary. Every accepted mutation commits to SQLite before reply."
  use GenServer
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def read(fun), do: GenServer.call(__MODULE__, {:read, fun})
  def transact(fun), do: GenServer.call(__MODULE__, {:write, fun}, 15_000)
  def reset, do: transact(fn _ -> {:ok, empty()} end)
  def empty, do: %{services: %{}, tasks: %{}, events: [], seq: %{}, keys: %{}, counters: %{}}

  def init(_opts) do
    path = Application.fetch_env!(:rutvi_exercise, :database_path)
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)"
      )

    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT payload FROM state WHERE id=1")

    data =
      case Exqlite.Sqlite3.step(db, stmt) do
        {:row, [blob]} -> :erlang.binary_to_term(blob)
        :done -> empty()
      end

    Exqlite.Sqlite3.release(db, stmt)
    {:ok, %{db: db, data: data}}
  end

  def handle_call({:read, fun}, _, state), do: {:reply, fun.(state.data), state}

  def handle_call({:write, fun}, _, state) do
    {reply, data} = fun.(state.data)

    if data == state.data do
      {:reply, reply, state}
    else
      :ok = Exqlite.Sqlite3.execute(state.db, "BEGIN IMMEDIATE")

      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          state.db,
          "INSERT INTO state(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload"
        )

      :ok = Exqlite.Sqlite3.bind(stmt, [{:blob, :erlang.term_to_binary(data)}])
      :done = Exqlite.Sqlite3.step(state.db, stmt)
      :ok = Exqlite.Sqlite3.release(state.db, stmt)
      :ok = Exqlite.Sqlite3.execute(state.db, "COMMIT")
      {:reply, reply, %{state | data: data}}
    end
  end

  def event(data, task, type, details \\ %{}) do
    seq = Map.get(data.seq, task.run_id, 0) + 1

    event =
      Map.merge(
        %{
          event_id: id(),
          sequence: seq,
          run_id: task.run_id,
          task_id: task.task_id,
          parent_id: task.parent_id,
          service_id: task.service_id,
          request_id: task.request_id,
          timestamp: System.system_time(:millisecond),
          type: type
        },
        details
      )

    %{data | events: data.events ++ [event], seq: Map.put(data.seq, task.run_id, seq)}
  end

  def id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
