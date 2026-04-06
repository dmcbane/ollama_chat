defmodule OllamaChat.BuiltinTools.Memory.Save do
  @moduledoc """
  Built-in tool that saves a new memory entry about the user or conversation.

  The LLM should call this tool when it learns something important that should
  be remembered across conversations — a user preference, a fact about the user,
  ongoing project context, or a significant episode from the conversation.

  The memory is persisted to PostgreSQL and an embedding is generated
  asynchronously for future semantic retrieval.
  """

  @behaviour OllamaChat.BuiltinTool

  alias OllamaChat.Memory

  @impl true
  def name, do: "memory_save"

  @impl true
  def description do
    "Save a new memory about the user or conversation. Use this when you learn something " <>
      "important about the user's preferences, facts about them, or context about their work. " <>
      "Do NOT tell the user you are saving a memory unless they ask."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "required" => ["content"],
      "properties" => %{
        "content" => %{
          "type" => "string",
          "description" =>
            "The memory content to save. Be specific and concise (e.g. " <>
              "\"User prefers Elixir over Python for backend work\")."
        },
        "memory_type" => %{
          "type" => "string",
          "enum" => ["fact", "preference", "context", "episodic"],
          "default" => "fact",
          "description" =>
            "The type of memory: " <>
              "fact (objective info about the user), " <>
              "preference (what the user likes/dislikes), " <>
              "context (ongoing project or situation), " <>
              "episodic (something that happened in a past session)."
        },
        "category" => %{
          "type" => "string",
          "description" =>
            ~s[Optional category for grouping (e.g. "programming", "personal", "work"). ] <>
              "Max 50 characters."
        },
        "importance" => %{
          "type" => "number",
          "minimum" => 0.0,
          "maximum" => 1.0,
          "default" => 0.5,
          "description" =>
            "Importance score from 0.0 (low) to 1.0 (critical). " <>
              "Use 0.8+ for critical preferences or facts, 0.5 for normal info, " <>
              "0.2 for minor/incidental details."
        }
      }
    }
  end

  @impl true
  def execute(args) when is_map(args) do
    content = Map.get(args, "content")

    if is_nil(content) or content == "" do
      {:error, "content is required and must be a non-empty string"}
    else
      attrs = %{
        content: content,
        memory_type: Map.get(args, "memory_type") || "fact",
        source: "llm_explicit",
        importance: parse_importance(Map.get(args, "importance")),
        category: Map.get(args, "category")
      }

      case Memory.create_memory_with_embedding(attrs) do
        {:ok, entry} ->
          importance_label = importance_label(entry.importance)

          {:ok,
           "Memory saved (id: #{entry.id}): " <>
             "\"#{entry.content}\" " <>
             "(#{entry.memory_type}, #{importance_label} importance)"}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, "Failed to save memory: #{format_changeset_errors(changeset)}"}

        {:error, :memory_disabled} ->
          {:error, "Memory system is disabled"}

        {:error, :database_unavailable} ->
          {:error, "Memory database is unavailable"}

        {:error, reason} ->
          {:error, "Failed to save memory: #{inspect(reason)}"}
      end
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp parse_importance(nil), do: 0.5
  defp parse_importance(v) when is_float(v), do: clamp(v, 0.0, 1.0)
  defp parse_importance(v) when is_integer(v), do: clamp(v / 1, 0.0, 1.0)

  defp parse_importance(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> clamp(f, 0.0, 1.0)
      :error -> 0.5
    end
  end

  defp parse_importance(_), do: 0.5

  defp clamp(v, lo, hi), do: max(lo, min(hi, v))

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> inspect()
  end

  defp importance_label(i) when i >= 0.7, do: "high"
  defp importance_label(i) when i >= 0.4, do: "medium"
  defp importance_label(_), do: "low"
end
