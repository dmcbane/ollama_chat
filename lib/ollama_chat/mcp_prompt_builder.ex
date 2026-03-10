defmodule OllamaChat.MCPPromptBuilder do
  @moduledoc """
  Builds system prompts that teach LLMs to use MCP tools.

  This module creates structured system prompts that:
  - Describe available tools to the LLM
  - Teach the tool calling format
  - Provide clear examples
  - Handle cases where no tools are available

  Since Ollama may not have native function calling support like OpenAI/Anthropic,
  we use structured prompting to teach the model how to request tool execution.
  """

  @doc """
  Builds a tool-aware system prompt from available tools.

  Returns a system prompt string that includes:
  - Base instruction about tool availability
  - Formatted list of tools with descriptions and schemas
  - Tool calling format instructions
  - Example usage

  ## Parameters

    - tools: Map of tool names to tool information
    - base_prompt: Optional base system prompt to prepend (default: nil)

  ## Examples

      iex> tools = %{
      ...>   "read_file" => %{
      ...>     description: "Read a file's contents",
      ...>     schema: %{"properties" => %{"path" => %{"type" => "string"}}}
      ...>   }
      ...> }
      iex> MCPPromptBuilder.build_tool_aware_system_prompt(tools)
      "You are an AI assistant with access to tools..."

  """
  @spec build_tool_aware_system_prompt(map(), String.t() | nil) :: String.t()
  def build_tool_aware_system_prompt(tools, base_prompt \\ nil) when is_map(tools) do
    if map_size(tools) == 0 do
      base_prompt || default_system_prompt()
    else
      parts = [
        base_prompt,
        tools_available_section(),
        format_tools(tools),
        tool_calling_instructions(),
        tool_calling_example()
      ]

      parts
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
    end
  end

  @doc """
  Builds a system prompt without tool information.
  Used when MCP is disabled or no tools are available.
  """
  @spec build_standard_system_prompt(String.t() | nil) :: String.t()
  def build_standard_system_prompt(base_prompt \\ nil) do
    base_prompt || default_system_prompt()
  end

  # Private Functions

  defp default_system_prompt do
    """
    You are a helpful AI assistant. Provide clear, accurate, and concise responses.
    When asked questions, think carefully and provide well-reasoned answers.
    """
  end

  defp tools_available_section do
    """
    You are an AI assistant with access to external tools that can help you accomplish tasks.
    You can use these tools to read files, get information, perform calculations, and more.
    """
  end

  defp format_tools(tools) do
    tool_list =
      tools
      |> Enum.map(fn {name, info} ->
        format_single_tool(name, info)
      end)
      |> Enum.join("\n\n")

    """
    ## Available Tools:

    #{tool_list}
    """
  end

  defp format_single_tool(name, info) do
    description = Map.get(info, :description, "No description available")
    schema = Map.get(info, :schema, %{})
    requires_approval = Map.get(info, :requires_approval, false)

    approval_note =
      if requires_approval do
        " (requires user approval)"
      else
        ""
      end

    params = format_parameters(schema)

    """
    ### #{name}#{approval_note}
    #{description}

    Parameters:
    #{params}
    """
  end

  defp format_parameters(schema) when is_map(schema) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    if map_size(properties) == 0 do
      "  (no parameters required)"
    else
      properties
      |> Enum.map(fn {key, value} ->
        format_parameter(key, value, key in required)
      end)
      |> Enum.join("\n")
    end
  end

  defp format_parameters(_), do: "  (no parameters required)"

  defp format_parameter(key, value, required) do
    type = Map.get(value, "type", "string")
    description = Map.get(value, "description", "")
    required_marker = if required, do: " (required)", else: " (optional)"

    "  - #{key} (#{type})#{required_marker}: #{description}"
  end

  defp tool_calling_instructions do
    """
    ## How to Use Tools:

    When you need to use a tool, respond with ONLY a JSON object in this exact format:
    ```json
    {"tool_call": {"name": "tool_name", "arguments": {"param1": "value1", "param2": "value2"}}}
    ```

    IMPORTANT:
    - Use ONLY the tool names listed above
    - Provide all required parameters
    - Use the exact JSON format shown
    - Do not include any other text with the tool call
    - Wait for the tool result before continuing your response

    After receiving tool results, continue your response naturally, incorporating the information you received.

    If you don't need any tools to answer a question, respond normally without using the tool call format.
    """
  end

  defp tool_calling_example do
    """
    ## Example:

    User: "What's in the file config.json?"

    You (tool call):
    ```json
    {"tool_call": {"name": "read_file", "arguments": {"path": "config.json"}}}
    ```

    System (tool result): {"port": 4000, "host": "localhost"}

    You (final response):
    The config.json file contains configuration settings with the port set to 4000 and the host set to localhost.
    """
  end

  @doc """
  Builds a message with tool result context.

  Creates a message that injects tool results back into the conversation
  for the LLM to process and continue its response.

  ## Parameters

    - tool_name: The name of the tool that was executed
    - result: The result from the tool (list of content items)

  ## Returns

    A formatted message string with the tool result

  """
  @spec build_tool_result_message(String.t(), list()) :: String.t()
  def build_tool_result_message(tool_name, result) when is_list(result) do
    formatted_result = format_tool_result(result)

    """
    Tool "#{tool_name}" returned the following result:

    #{formatted_result}

    Please continue your response using this information.
    """
  end

  defp format_tool_result(result) when is_list(result) do
    result
    |> Enum.map(fn
      %{"type" => "text", "text" => text} ->
        text

      %{"type" => "image", "data" => _data, "mimeType" => mime_type} ->
        "[Image: #{mime_type}]"

      %{"type" => "resource"} = resource ->
        uri = Map.get(resource, "uri", "unknown")
        "[Resource: #{uri}]"

      other ->
        inspect(other)
    end)
    |> Enum.join("\n\n")
  end

  @doc """
  Extracts the tool name from a tool info map.

  Used when building prompts that need to reference specific tools.
  """
  @spec get_tool_name(map()) :: String.t()
  def get_tool_name(tool_info) when is_map(tool_info) do
    Map.get(tool_info, :name, "unknown")
  end

  @doc """
  Checks if a system prompt contains tool instructions.

  Useful for determining if we need to rebuild the system prompt
  when tools change.
  """
  @spec has_tool_instructions?(String.t()) :: boolean()
  def has_tool_instructions?(prompt) when is_binary(prompt) do
    String.contains?(prompt, "Available Tools:") or
      String.contains?(prompt, "tool_call")
  end

  @doc """
  Builds a prompt warning about dangerous tool operations.

  Used when a tool requires approval to inform the LLM that
  user confirmation is needed.
  """
  @spec build_approval_notice(String.t()) :: String.t()
  def build_approval_notice(tool_name) do
    """
    Note: The tool "#{tool_name}" requires user approval before execution.
    The user will be prompted to approve or deny this operation.
    """
  end

  @doc """
  Builds a compact tool summary for UI display.

  Returns a brief, human-readable summary of available tools.
  """
  @spec build_tool_summary(map()) :: String.t()
  def build_tool_summary(tools) when is_map(tools) do
    count = map_size(tools)

    case count do
      0 ->
        "No tools available"

      1 ->
        {name, _} = Enum.at(tools, 0)
        "1 tool available: #{name}"

      _ ->
        names =
          tools
          |> Map.keys()
          |> Enum.take(3)
          |> Enum.join(", ")

        remaining = count - 3

        if remaining > 0 do
          "#{count} tools available: #{names}, and #{remaining} more"
        else
          "#{count} tools available: #{names}"
        end
    end
  end
end
