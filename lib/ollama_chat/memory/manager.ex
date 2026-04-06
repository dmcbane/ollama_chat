defmodule OllamaChat.Memory.Manager do
  @moduledoc """
  GenServer that runs periodic memory maintenance tasks.

  On startup it schedules one maintenance run per day (configurable via
  `:memory_maintenance_interval_ms`).  Each run:

  1. Calls `Memory.decay_importance/0` — reduces importance of unused memories.
  2. Calls `Memory.prune_to_limit/0`   — deletes lowest-scored memories above
     the configured maximum count.

  ## Manual trigger

      OllamaChat.Memory.Manager.run_maintenance_now()

  ## Configuration

  | Key                                  | Default          | Description                  |
  |--------------------------------------|------------------|------------------------------|
  | `:memory_maintenance_interval_ms`    | 86_400_000 (24h) | Interval between runs        |
  | `:memory_max_count`                  | 1_000            | Max memories before pruning  |
  """

  use GenServer
  require Logger

  alias OllamaChat.Memory

  @default_interval_ms 86_400_000

  # ── Public API ───────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers a maintenance run asynchronously. Returns `:ok` immediately.
  """
  @spec run_maintenance_now() :: :ok
  def run_maintenance_now do
    GenServer.cast(__MODULE__, :run_maintenance)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_maintenance()
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:run_maintenance, state) do
    do_maintenance()
    {:noreply, state}
  end

  @impl true
  def handle_info(:run_maintenance, state) do
    do_maintenance()
    schedule_maintenance()
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp do_maintenance do
    if Memory.enabled?() and Memory.available?() do
      Logger.info("Memory.Manager: starting maintenance run")

      case Memory.decay_importance() do
        {:ok, count} ->
          Logger.info("Memory.Manager: decayed #{count} memories")

        {:error, reason} ->
          Logger.warning("Memory.Manager: decay failed: #{inspect(reason)}")
      end

      case Memory.prune_to_limit() do
        {:ok, 0} ->
          :ok

        {:ok, count} ->
          Logger.info("Memory.Manager: pruned #{count} memories")

        {:error, reason} ->
          Logger.warning("Memory.Manager: prune failed: #{inspect(reason)}")
      end

      Logger.info("Memory.Manager: maintenance complete")
    else
      Logger.debug("Memory.Manager: skipping maintenance (memory unavailable)")
    end
  end

  defp schedule_maintenance do
    interval =
      Application.get_env(
        :ollama_chat,
        :memory_maintenance_interval_ms,
        @default_interval_ms
      )

    Process.send_after(self(), :run_maintenance, interval)
  end
end
