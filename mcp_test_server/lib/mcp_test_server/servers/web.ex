defmodule McpTestServer.Servers.Web do
  @moduledoc """
  MCP server providing web search via DuckDuckGo's Instant Answer API.

  No API key required. Uses Erlang's built-in :httpc (from :inets) for HTTP
  requests — no additional dependencies beyond :jason.
  """

  @behaviour McpTestServer.ServerBehaviour

  @impl true
  def server_name, do: "mcp-web"

  @impl true
  def list_tools do
    [
      %{
        name: "web_search",
        description:
          "Search the web using DuckDuckGo Instant Answers. Returns abstract summaries, instant answers, and related topics for a query. Good for factual lookups, definitions, and general knowledge.",
        inputSchema: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "The search query"},
            max_results: %{
              type: "integer",
              description: "Maximum number of related topics to include (default 5)",
              default: 5
            }
          },
          required: ["query"]
        }
      }
    ]
  end

  @impl true
  def execute_tool(tool_name, arguments) do
    case tool_name do
      "web_search" -> handle_web_search(arguments)
      _ -> %{isError: true, content: [%{type: "text", text: "Unknown tool: #{tool_name}"}]}
    end
  end

  # Handlers

  defp handle_web_search(%{"query" => query} = args) do
    max_results = Map.get(args, "max_results", 5)
    encoded = URI.encode_www_form(query)

    url =
      String.to_charlist(
        "https://api.duckduckgo.com/?q=#{encoded}&format=json&no_html=1&skip_disambig=1"
      )

    headers = [{~c"User-Agent", ~c"McpTestServer/0.4.0"}]
    ssl_opts = [{:ssl, [{:verify, :verify_none}]}]

    case :httpc.request(:get, {url, headers}, ssl_opts, []) do
      {:ok, {{_, 200, _}, _resp_headers, body}} ->
        body_str = if is_list(body), do: List.to_string(body), else: body

        case Jason.decode(body_str) do
          {:ok, data} ->
            format_duckduckgo_response(query, data, max_results)

          {:error, _} ->
            %{isError: true, content: [%{type: "text", text: "Failed to parse search response"}]}
        end

      {:ok, {{_, status, _}, _, _}} ->
        %{isError: true, content: [%{type: "text", text: "Search API returned status #{status}"}]}

      {:error, reason} ->
        %{
          isError: true,
          content: [%{type: "text", text: "Search request failed: #{inspect(reason)}"}]
        }
    end
  end

  defp handle_web_search(_) do
    %{isError: true, content: [%{type: "text", text: "Missing required parameter: query"}]}
  end

  defp format_duckduckgo_response(query, data, max_results) do
    answer = data["Answer"] || ""
    abstract = data["AbstractText"] || ""
    source_url = data["AbstractURL"] || ""
    definition = data["Definition"] || ""
    related_topics = data["RelatedTopics"] || []

    sections =
      []
      |> maybe_prepend(answer != "", "**Instant Answer:** #{answer}")
      |> maybe_prepend(
        abstract != "",
        abstract <> if(source_url != "", do: "\n(Source: #{source_url})", else: "")
      )
      |> maybe_prepend(definition != "", "**Definition:** #{definition}")

    related_items =
      related_topics
      |> Enum.take(max_results)
      |> Enum.flat_map(fn topic ->
        cond do
          is_map(topic) && is_binary(topic["Text"]) && topic["Text"] != "" ->
            [topic["Text"]]

          is_map(topic) && is_list(topic["Topics"]) ->
            topic["Topics"]
            |> Enum.take(3)
            |> Enum.map(& &1["Text"])
            |> Enum.reject(&is_nil/1)

          true ->
            []
        end
      end)

    sections =
      maybe_prepend(
        sections,
        related_items != [],
        "**Related Topics:**\n" <> Enum.map_join(related_items, "\n", &"• #{&1}")
      )

    text =
      if sections == [] do
        "No results found for: #{query}"
      else
        sections |> Enum.reverse() |> Enum.join("\n\n")
      end

    %{content: [%{type: "text", text: "Search results for \"#{query}\":\n\n#{text}"}]}
  end

  defp maybe_prepend(list, true, item), do: [item | list]
  defp maybe_prepend(list, false, _item), do: list
end
