defmodule OllamaChat.BuiltinTools.Memory.Update do
  @moduledoc """
  Built-in tool that lets the LLM update an existing memory entry.

  The LLM must supply the memory `id` (obtainable via `memory_list` or
  `memory_search`) plus any subset of fields to change.  Fields omitted
  from the call are left unchanged.
  """

  @behaviour OllamaChat.BuiltinTool

  alias OllamaChat.Memory

  @impl true
  def name, do: "memory_update"

  @impl true
  def description do
    "Update an existing memory entry. Use this when a previously saved memory " <>
      "is outdated or incorrect. Supply the memory id (from memory_list or " <>
      "memory_search) and the fields you want to change."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "required" => ["id"],
      "properties" => %{
        "id" => %{
          "type" => "string",
          "description" => "The UUID of the memory entry to update"
        },
        "content" => %{
          "type" => "string",
          "description" => "New content for the memory"
        },
        "memory_type" => %{
          "type" => "string",
          "enum" => ["fact", "preference", "context", "episodic"],
          "description" => "New memory type"
        },
        "category" => %{
          "type" => "string",
          "description" => "New category label (max 50 chars)"
        },
        "importance" => %{
          "type" => "number",
          "minimum" => 0.0,
          "maximum" => 1.0,
          "description" => "New importance score (0.0–1.0)"
        }
      }
    }
  end

  @impl true
  def execute(args) do
    id = args["id"]

    if is_nil(id) or id == "" do
      {:error, "memory_update requires an \"id\" parameter"}
    else
      do_update(id, build_update_attrs(args))
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp build_update_attrs(args) do
    args
    |> Map.take(["content", "memory_type", "category", "importance"])
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp do_update(_id, attrs) when map_size(attrs) == 0 do
    {:error,
     "memory_update requires at least one field to change (content, memory_type, category, or importance)"}
  end

  defp do_update(id, attrs) do
    case Memory.get_memory(id) do
      {:ok, nil} ->
        {:error, "No memory found with id: #{id}"}

      {:ok, entry} ->
        case Memory.update_memory(entry, attrs) do
          {:ok, updated} ->
            {:ok,
             "Memory updated (id: #{updated.id}): " <>
               "\"#{updated.content}\" " <>
               "(#{updated.memory_type}, importance: #{updated.importance})"}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:error, "Failed to update memory: #{format_changeset_errors(changeset)}"}

          {:error, reason} ->
            {:error, "Failed to update memory: #{inspect(reason)}"}
        end

      {:error, :memory_disabled} ->
        {:error, "Memory system is disabled"}

      {:error, :database_unavailable} ->
        {:error, "Memory database is unavailable"}

      {:error, reason} ->
        {:error, "Could not retrieve memory: #{inspect(reason)}"}
    end
  end

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> inspect()
  end
end
