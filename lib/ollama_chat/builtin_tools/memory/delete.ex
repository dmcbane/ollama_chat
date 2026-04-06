defmodule OllamaChat.BuiltinTools.Memory.Delete do
  @moduledoc """
  Built-in tool: `memory_delete`

  Deletes a memory entry by its ID. Use this when a stored memory is no
  longer accurate, is outdated, or the user explicitly asks to forget
  something.
  """

  @behaviour OllamaChat.BuiltinTool

  alias OllamaChat.Memory

  require Logger

  @impl true
  def name, do: "memory_delete"

  @impl true
  def description do
    "Delete a memory that is no longer accurate or that the user wants forgotten. " <>
      "Use memory_search or memory_list first to find the correct memory ID."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "required" => ["id"],
      "properties" => %{
        "id" => %{
          "type" => "string",
          "description" => "The UUID of the memory entry to delete"
        }
      }
    }
  end

  @impl true
  def execute(%{"id" => id}) when is_binary(id) and id != "" do
    case Memory.delete_memory_by_id(id) do
      {:ok, _} ->
        Logger.info("Memory deleted via tool: #{id}")
        {:ok, "Memory #{id} has been deleted."}

      {:error, :not_found} ->
        {:error, "No memory found with ID #{id}."}

      {:error, :memory_disabled} ->
        {:error, "Memory system is currently disabled."}

      {:error, reason} ->
        Logger.warning("memory_delete tool failed for id=#{id}: #{inspect(reason)}")
        {:error, "Failed to delete memory: #{inspect(reason)}"}
    end
  end

  def execute(%{"id" => id}) when id == "" do
    {:error, "Memory ID cannot be empty."}
  end

  def execute(_args) do
    {:error, "Required parameter 'id' is missing."}
  end
end
