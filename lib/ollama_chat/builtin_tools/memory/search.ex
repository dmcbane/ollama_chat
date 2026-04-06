defmodule OllamaChat.BuiltinTools.Memory.Search do
  @moduledoc """
  Built-in tool: `memory_search`

  Searches stored memories using hybrid scoring (semantic similarity +
  importance + recency) when embeddings are available, with a full-text
  fallback otherwise.

  The LLM can call this tool to look up what it already knows about the
  user before answering a question.
  """

  @behaviour OllamaChat.BuiltinTool

  alias OllamaChat.Memory

  @default_limit 5

  @impl true
  def name, do: "memory_search"

  @impl true
  def description do
    "Search your stored memories for information relevant to a query. " <>
      "Use this when you want to recall something specific about the user or conversation context. " <>
      "Returns a list of matching memories with their IDs, types, and importance scores."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "required" => ["query"],
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "The search query — describe what you are trying to recall"
        },
        "limit" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 20,
          "default" => @default_limit,
          "description" => "Maximum number of memories to return (default: #{@default_limit})"
        },
        "memory_type" => %{
          "type" => "string",
          "enum" => ["fact", "preference", "context", "episodic"],
          "description" => "Filter results to a specific memory type (optional)"
        }
      }
    }
  end

  @impl true
  def execute(args) when is_map(args) do
    query = args["query"]

    if is_nil(query) or String.trim(query) == "" do
      {:error, "The 'query' parameter is required and must be a non-empty string."}
    else
      limit = parse_limit(args["limit"])
      opts = build_opts(limit, args["memory_type"])

      case Memory.retrieve_relevant(query, opts) do
        {:ok, []} ->
          {:ok, "No memories found matching \"#{query}\"."}

        {:ok, memories} ->
          {:ok, format_results(memories, query)}

        {:error, :memory_disabled} ->
          {:error, "Memory system is disabled."}

        {:error, :database_unavailable} ->
          {:error, "Memory database is currently unavailable."}

        {:error, reason} ->
          {:error, "Memory search failed: #{inspect(reason)}"}
      end
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp parse_limit(nil), do: @default_limit
  defp parse_limit(limit) when is_integer(limit) and limit >= 1, do: min(limit, 20)
  defp parse_limit(_), do: @default_limit

  defp build_opts(limit, nil), do: [limit: limit]
  defp build_opts(limit, memory_type), do: [limit: limit, memory_type: memory_type]

  defp format_results(memories, query) do
    count = length(memories)
    header = "Found #{count} #{pluralize(count, "memory", "memories")} matching \"#{query}\":"

    lines =
      Enum.map_join(memories, "\n", fn entry ->
        importance_label = importance_label(entry.importance)
        date = format_date(entry.inserted_at)

        "- [id: #{entry.id}] #{entry.content}" <>
          " (#{entry.memory_type}, #{importance_label}, learned #{date})"
      end)

    header <> "\n" <> lines
  end

  defp importance_label(i) when i >= 0.8, do: "high importance"
  defp importance_label(i) when i >= 0.5, do: "medium importance"
  defp importance_label(_), do: "low importance"

  defp format_date(nil), do: "unknown date"

  defp format_date(dt) do
    Calendar.strftime(dt, "%b %-d, %Y")
  rescue
    _ -> "unknown date"
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_, _singular, plural), do: plural
end
