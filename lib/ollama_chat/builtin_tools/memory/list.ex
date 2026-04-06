defmodule OllamaChat.BuiltinTools.Memory.List do
  @moduledoc """
  Built-in tool that lists stored memories.

  The LLM can call this to review what has been remembered about the user,
  optionally filtering by memory type and limiting the number of results.
  """

  @behaviour OllamaChat.BuiltinTool

  alias OllamaChat.Memory

  require Logger

  @impl true
  def name, do: "memory_list"

  @impl true
  def description do
    "List memories that have been saved about the user or conversation context. " <>
      "Use this to review what you remember before answering questions about the user's " <>
      "preferences, history, or context. Optionally filter by memory type."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "required" => [],
      "properties" => %{
        "memory_type" => %{
          "type" => "string",
          "enum" => ["fact", "preference", "context", "episodic"],
          "description" => "Filter results to only this memory type. Omit to list all types."
        },
        "limit" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 50,
          "default" => 10,
          "description" => "Maximum number of memories to return (default: 10)."
        }
      }
    }
  end

  @impl true
  def execute(args) do
    opts = build_opts(args)

    case Memory.list_memories(opts) do
      {:ok, []} ->
        filter_note =
          case args["memory_type"] do
            nil -> ""
            type -> " of type \"#{type}\""
          end

        {:ok, "No memories found#{filter_note}."}

      {:ok, entries} ->
        formatted = format_entries(entries)
        filter_note = if args["memory_type"], do: " (type: #{args["memory_type"]})", else: ""

        {:ok,
         "#{length(entries)} memory#{if length(entries) == 1, do: "", else: "s"} found#{filter_note}:\n\n#{formatted}"}

      {:error, :memory_disabled} ->
        {:error, "Memory system is disabled."}

      {:error, :database_unavailable} ->
        {:error, "Memory database is currently unavailable."}

      {:error, reason} ->
        Logger.warning("memory_list failed: #{inspect(reason)}")
        {:error, "Failed to list memories: #{inspect(reason)}"}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp build_opts(args) do
    []
    |> maybe_put(:memory_type, args["memory_type"])
    |> maybe_put(:limit, parse_limit(args["limit"]))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_limit(nil), do: 10
  defp parse_limit(n) when is_integer(n) and n >= 1, do: min(n, 50)
  defp parse_limit(_), do: 10

  defp format_entries(entries) do
    Enum.map_join(entries, "\n", &format_entry/1)
  end

  defp format_entry(entry) do
    importance_label =
      cond do
        entry.importance >= 0.8 -> "high"
        entry.importance >= 0.5 -> "medium"
        true -> "low"
      end

    date_label =
      if entry.inserted_at do
        Calendar.strftime(entry.inserted_at, "%b %-d, %Y")
      else
        "unknown date"
      end

    category_note =
      if entry.category, do: ", category: #{entry.category}", else: ""

    "- [id: #{entry.id}] #{entry.content}\n" <>
      "  (#{entry.memory_type}, #{importance_label} importance#{category_note}, learned #{date_label})"
  end
end
