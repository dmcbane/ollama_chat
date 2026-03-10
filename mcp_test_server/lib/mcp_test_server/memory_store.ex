defmodule McpTestServer.MemoryStore do
  @moduledoc """
  In-memory key-value store for the MCP test server.

  Provides simple get/set/delete operations with optional TTL support.
  """
  use GenServer
  require Logger

  @cleanup_interval 60_000

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a value with an optional TTL in seconds.
  """
  def set(key, value, ttl \\ nil) when is_binary(key) do
    GenServer.call(__MODULE__, {:set, key, value, ttl})
  end

  @doc """
  Retrieve a value by key.
  """
  def get(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc """
  Delete a value by key.
  """
  def delete(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:delete, key})
  end

  @doc """
  List all keys in the store.
  """
  def list_keys do
    GenServer.call(__MODULE__, :list_keys)
  end

  @doc """
  Clear all entries from the store.
  """
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Schedule periodic cleanup of expired entries
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:set, key, value, ttl}, _from, state) do
    entry =
      if ttl do
        %{value: value, expires_at: System.system_time(:second) + ttl}
      else
        %{value: value, expires_at: nil}
      end

    new_state = Map.put(state, key, entry)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    case Map.get(state, key) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{expires_at: expires_at} = entry when not is_nil(expires_at) ->
        now = System.system_time(:second)

        if now > expires_at do
          # Entry expired, remove it
          new_state = Map.delete(state, key)
          {:reply, {:error, :not_found}, new_state}
        else
          {:reply, {:ok, entry.value}, state}
        end

      entry ->
        {:reply, {:ok, entry.value}, state}
    end
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    case Map.get(state, key) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _entry ->
        new_state = Map.delete(state, key)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:list_keys, _from, state) do
    now = System.system_time(:second)

    valid_keys =
      state
      |> Enum.filter(fn {_key, entry} ->
        case entry.expires_at do
          nil -> true
          expires_at -> now <= expires_at
        end
      end)
      |> Enum.map(fn {key, _entry} -> key end)

    {:reply, {:ok, valid_keys}, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)

    new_state =
      state
      |> Enum.filter(fn {_key, entry} ->
        case entry.expires_at do
          nil -> true
          expires_at -> now <= expires_at
        end
      end)
      |> Enum.into(%{})

    removed_count = map_size(state) - map_size(new_state)

    if removed_count > 0 do
      Logger.debug("Cleaned up #{removed_count} expired entries")
    end

    # Schedule next cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)

    {:noreply, new_state}
  end
end
