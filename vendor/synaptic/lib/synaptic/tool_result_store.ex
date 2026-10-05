defmodule Synaptic.ToolResultStore do
  @moduledoc """
  Ephemeral storage for oversized or compacted tool results.

  Handles returned by the context hygiene layer can be resolved through this
  module for follow-up retrieval outside the model prompt.
  """

  @table :synaptic_tool_result_store
  @default_ttl_ms 15 * 60 * 1000

  @type entry :: %{
          handle: String.t(),
          result: term(),
          metadata: map(),
          inserted_at: non_neg_integer(),
          expires_at: non_neg_integer()
        }

  @spec put(term(), map(), pos_integer() | nil) :: String.t()
  def put(result, metadata \\ %{}, ttl_ms \\ @default_ttl_ms) when is_map(metadata) do
    ensure_table!()

    handle = "spill_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    now = System.system_time(:millisecond)
    ttl = normalize_ttl(ttl_ms)

    entry = %{
      result: result,
      metadata: metadata,
      inserted_at: now,
      expires_at: now + ttl
    }

    true = :ets.insert(@table, {handle, entry})
    handle
  end

  @spec fetch(String.t(), keyword()) ::
          {:ok, entry()} | {:error, :not_found | :expired | :forbidden}
  def fetch(handle, opts \\ []) when is_binary(handle) and is_list(opts) do
    ensure_table!()
    tenant = Keyword.get(opts, :tenant) || get_from_context(:__tenant__)

    case :ets.lookup(@table, handle) do
      [{^handle, entry}] ->
        if expired?(entry) do
          :ets.delete(@table, handle)
          {:error, :expired}
        else
          with :ok <- authorize_tenant(entry, tenant) do
            {:ok, Map.put(entry, :handle, handle)}
          end
        end

      [] ->
        {:error, :not_found}
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(handle) when is_binary(handle) do
    ensure_table!()
    :ets.delete(@table, handle)
    :ok
  end

  @spec delete_by_run(String.t()) :: non_neg_integer()
  def delete_by_run(run_id) when is_binary(run_id) do
    ensure_table!()

    :ets.foldl(
      fn {handle, entry}, acc ->
        metadata = Map.get(entry, :metadata, %{})

        if Map.get(metadata, :run_id) == run_id or Map.get(metadata, "run_id") == run_id do
          :ets.delete(@table, handle)
          acc + 1
        else
          acc
        end
      end,
      0,
      @table
    )
  end

  @spec prune_expired() :: non_neg_integer()
  def prune_expired do
    ensure_table!()
    now = System.system_time(:millisecond)

    :ets.foldl(
      fn {handle, entry}, acc ->
        if Map.get(entry, :expires_at, now) < now do
          :ets.delete(@table, handle)
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
            :set,
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

  defp authorize_tenant(%{metadata: metadata}, tenant) do
    expected = Map.get(metadata, :tenant) || Map.get(metadata, "tenant")

    cond do
      is_nil(expected) -> :ok
      expected == tenant -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp get_from_context(key) do
    case Process.get({:synaptic_context, key}) do
      nil -> nil
      value -> value
    end
  end
end
