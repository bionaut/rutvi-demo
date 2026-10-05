defmodule Synaptic.AuditStore do
  @moduledoc """
  Ephemeral append-only audit storage for guardrail and workflow safety events.

  Records are stored with TTL-based retention and can be queried by `audit_id`
  (which is usually the workflow `run_id` when one exists).
  """

  @table :synaptic_audit_store
  @default_ttl_ms 7 * 24 * 60 * 60 * 1000

  @type entry :: %{
          record_id: String.t(),
          audit_id: String.t(),
          run_id: String.t() | nil,
          category: atom() | String.t(),
          event: atom() | String.t(),
          metadata: map(),
          sequence: non_neg_integer(),
          prev_hash: String.t() | nil,
          hash: String.t(),
          inserted_at: non_neg_integer(),
          expires_at: non_neg_integer()
        }

  @spec put(
          String.t(),
          String.t() | nil,
          atom() | String.t(),
          atom() | String.t(),
          map(),
          pos_integer() | nil
        ) ::
          entry()
  def put(audit_id, run_id, category, event, metadata, ttl_ms \\ @default_ttl_ms)
      when is_binary(audit_id) and is_map(metadata) do
    ensure_table!()

    :global.trans({{__MODULE__, audit_id}, self()}, fn ->
      do_put(audit_id, run_id, category, event, metadata, ttl_ms)
    end)
  end

  defp do_put(audit_id, run_id, category, event, metadata, ttl_ms) do
    now = System.system_time(:millisecond)
    ttl = normalize_ttl(ttl_ms)
    record_id = "audit_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    inserted_at = now
    sequence = :erlang.unique_integer([:positive, :monotonic])
    prev_hash = latest_hash(audit_id)

    entry = %{
      record_id: record_id,
      audit_id: audit_id,
      run_id: run_id,
      category: category,
      event: event,
      metadata: metadata,
      sequence: sequence,
      prev_hash: prev_hash,
      inserted_at: inserted_at,
      hash:
        compute_hash(%{
          record_id: record_id,
          audit_id: audit_id,
          run_id: run_id,
          category: category,
          event: event,
          metadata: metadata,
          sequence: sequence,
          prev_hash: prev_hash,
          inserted_at: inserted_at
        }),
      expires_at: now + ttl
    }

    true = :ets.insert(@table, {audit_id, record_id, entry})
    entry
  end

  @spec records(String.t()) :: [entry()]
  def records(audit_id) when is_binary(audit_id) do
    ensure_table!()

    @table
    |> :ets.lookup(audit_id)
    |> Enum.reduce([], fn
      {^audit_id, record_id, entry}, acc ->
        if expired?(entry) do
          :ets.delete_object(@table, {audit_id, record_id, entry})
          acc
        else
          [entry | acc]
        end
    end)
    |> Enum.sort_by(&{&1.inserted_at, &1.sequence}, :asc)
  end

  @spec verify_chain(String.t()) :: :ok | {:error, {:broken_chain, String.t()}}
  def verify_chain(audit_id) when is_binary(audit_id) do
    entries = records(audit_id)
    retained_prefix_hash = entries |> List.first() |> then(&(&1 && &1.prev_hash))

    entries
    |> Enum.reduce_while(retained_prefix_hash, fn entry, previous_hash ->
      expected_hash =
        compute_hash(%{
          record_id: entry.record_id,
          audit_id: entry.audit_id,
          run_id: entry.run_id,
          category: entry.category,
          event: entry.event,
          metadata: entry.metadata,
          sequence: entry.sequence,
          prev_hash: previous_hash,
          inserted_at: entry.inserted_at
        })

      cond do
        entry.prev_hash != previous_hash ->
          {:halt, {:error, {:broken_chain, entry.record_id}}}

        entry.hash != expected_hash ->
          {:halt, {:error, {:broken_chain, entry.record_id}}}

        true ->
          {:cont, entry.hash}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _ -> :ok
    end
  end

  @spec delete(String.t()) :: non_neg_integer()
  def delete(audit_id) when is_binary(audit_id) do
    ensure_table!()
    count = @table |> :ets.lookup(audit_id) |> length()
    :ets.match_delete(@table, {audit_id, :_, :_})
    count
  end

  @spec prune_expired() :: non_neg_integer()
  def prune_expired do
    ensure_table!()

    now = System.system_time(:millisecond)

    :ets.foldl(
      fn {audit_id, record_id, entry}, acc ->
        if Map.get(entry, :expires_at, now) < now do
          :ets.delete_object(@table, {audit_id, record_id, entry})
          acc + 1
        else
          acc
        end
      end,
      0,
      @table
    )
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [
            :named_table,
            :public,
            :bag,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  defp expired?(%{expires_at: expires_at}) do
    System.system_time(:millisecond) > expires_at
  end

  defp normalize_ttl(ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0, do: ttl_ms
  defp normalize_ttl(_ttl_ms), do: @default_ttl_ms

  defp latest_hash(audit_id) do
    audit_id
    |> records()
    |> List.last()
    |> case do
      nil -> nil
      entry -> entry.hash
    end
  end

  defp compute_hash(entry) do
    :sha256
    |> :crypto.hash(
      :erlang.term_to_binary([
        entry.record_id,
        entry.audit_id,
        entry.run_id,
        entry.category,
        entry.event,
        entry.metadata,
        entry.sequence,
        entry.prev_hash,
        entry.inserted_at
      ])
    )
    |> Base.encode16(case: :lower)
  end
end
