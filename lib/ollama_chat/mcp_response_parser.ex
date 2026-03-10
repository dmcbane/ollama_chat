defmodule OllamaChat.MCPResponseParser do
  @moduledoc """
  Parses LLM responses to detect and extract tool calls.

  This module handles parsing of LLM responses that may contain tool call requests.
  Since Ollama may not have native function calling support, we parse structured
  responses using multiple strategies:

  1. JSON parsing (primary) - Look for {"tool_call": {...}} format
  2. Text pattern matching (fallback) - Look for [TOOL_CALL: ...] patterns
  3. Code block extraction - Look for ```json tool calls

  The parser is designed to be forgiving and handle various response formats
  while maintaining security through validation.
  """

  require Logger

  @type tool_call :: {:tool_call, tool_name :: String.t(), arguments :: map()}
  @type parse_result :: tool_call() | :no_tool_call

  @doc """
  Attempts to parse a tool call from the LLM response.

  Tries multiple parsing strategies in order:
  1. Direct JSON parsing
  2. JSON code block extraction
  3. Text pattern matching

  ## Parameters

    - response_text: The raw response text from the LLM

  ## Returns

    - `{:tool_call, tool_name, arguments}` - If a tool call is detected
    - `:no_tool_call` - If no tool call is found

  ## Examples

      iex> MCPResponseParser.parse_response(~s({"tool_call": {"name": "read_file", "arguments": {"path": "test.txt"}}}))
      {:tool_call, "read_file", %{"path" => "test.txt"}}

      iex> MCPResponseParser.parse_response("Just a normal response")
      :no_tool_call

  """
  @spec parse_response(String.t()) :: parse_result()
  def parse_response(response_text) when is_binary(response_text) do
    response_text
    |> String.trim()
    |> try_parse_strategies()
  end

  def parse_response(_), do: :no_tool_call

  # Try parsing strategies in order
  defp try_parse_strategies(text) do
    with :no_tool_call <- try_json_parse(text),
         :no_tool_call <- try_code_block_parse(text) do
      try_text_pattern_parse(text)
    end
  end

  # Strategy 1: Direct JSON parsing
  defp try_json_parse(text) do
    case Jason.decode(text) do
      {:ok, %{"tool_call" => %{"name" => name, "arguments" => args}}} when is_binary(name) ->
        validate_and_return_tool_call(name, args)

      {:ok, _} ->
        :no_tool_call

      {:error, _} ->
        :no_tool_call
    end
  end

  # Strategy 2: Extract JSON from code blocks
  defp try_code_block_parse(text) do
    # Look for ```json ... ``` blocks - use non-greedy matching for nested braces
    case Regex.run(~r/```(?:json)?\s*(\{[^`]+\})\s*```/s, text) do
      [_, json_content] ->
        try_json_parse(json_content)

      _ ->
        # Also try to extract JSON object containing tool_call
        # Match balanced braces by finding the outermost { } containing "tool_call"
        case extract_json_with_tool_call(text) do
          {:ok, json_content} ->
            try_json_parse(json_content)

          :error ->
            :no_tool_call
        end
    end
  end

  # Helper to extract JSON with balanced braces containing "tool_call"
  defp extract_json_with_tool_call(text) do
    if String.contains?(text, "tool_call") do
      # Find the start of JSON object before tool_call
      case find_json_object_containing(text, "tool_call") do
        nil -> :error
        json -> {:ok, json}
      end
    else
      :error
    end
  end

  defp find_json_object_containing(text, search_term) do
    # Find position of search_term
    case :binary.match(text, search_term) do
      {pos, _len} ->
        # Look backwards for opening brace
        before = String.slice(text, 0, pos)
        start_pos = find_last_occurrence(before, "{")

        if start_pos do
          # Extract from opening brace and try to find balanced closing brace
          substring = String.slice(text, start_pos, String.length(text) - start_pos)
          extract_balanced_json(substring)
        else
          nil
        end

      :nomatch ->
        nil
    end
  end

  # Find the last occurrence of a substring
  defp find_last_occurrence(text, pattern) do
    case :binary.matches(text, pattern) do
      [] ->
        nil

      matches ->
        {pos, _len} = List.last(matches)
        pos
    end
  end

  defp extract_balanced_json(text) do
    case find_closing_brace(text, 0, 0) do
      {_depth, end_pos} when end_pos > 0 ->
        String.slice(text, 0, end_pos + 1)

      _ ->
        nil
    end
  end

  defp find_closing_brace(<<>>, depth, pos), do: {depth, pos}

  defp find_closing_brace(<<"{", rest::binary>>, depth, pos) do
    find_closing_brace(rest, depth + 1, pos + 1)
  end

  defp find_closing_brace(<<"}", _rest::binary>>, depth, pos) when depth == 1 do
    {0, pos}
  end

  defp find_closing_brace(<<"}", rest::binary>>, depth, pos) do
    find_closing_brace(rest, depth - 1, pos + 1)
  end

  defp find_closing_brace(<<_char, rest::binary>>, depth, pos) do
    find_closing_brace(rest, depth, pos + 1)
  end

  # Strategy 3: Text pattern matching (legacy/fallback)
  defp try_text_pattern_parse(text) do
    # Look for [TOOL_CALL: tool_name {args}] or similar patterns
    case Regex.run(~r/\[TOOL_CALL:\s*(\w+)\s+(\{.*?\})\]/s, text) do
      [_, name, args_json] ->
        case Jason.decode(args_json) do
          {:ok, args} when is_map(args) ->
            validate_and_return_tool_call(name, args)

          _ ->
            :no_tool_call
        end

      _ ->
        :no_tool_call
    end
  end

  # Validate and return tool call
  defp validate_and_return_tool_call(name, args) when is_binary(name) and is_map(args) do
    # Basic validation
    if String.length(name) > 0 and valid_tool_name?(name) do
      {:tool_call, name, args}
    else
      Logger.warning("Invalid tool name detected: #{inspect(name)}")
      :no_tool_call
    end
  end

  defp validate_and_return_tool_call(name, args) do
    Logger.warning("Invalid tool call format: name=#{inspect(name)}, args=#{inspect(args)}")
    :no_tool_call
  end

  # Validate tool name (alphanumeric, underscore, hyphen only)
  defp valid_tool_name?(name) do
    Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name)
  end

  @doc """
  Removes tool call JSON/patterns from response text for display.

  Cleans up the response so that tool call syntax doesn't appear
  in the chat UI while the tool is being executed.

  ## Examples

      iex> text = ~s({"tool_call": {"name": "read_file", "arguments": {"path": "test.txt"}}})
      iex> MCPResponseParser.strip_tool_call(text)
      ""

      iex> text = "Here's the file content: ```json\\n{\\"tool_call\\": {...}}\\n```"
      iex> MCPResponseParser.strip_tool_call(text)
      "Here's the file content:"

  """
  @spec strip_tool_call(String.t()) :: String.t()
  def strip_tool_call(response_text) when is_binary(response_text) do
    response_text
    # Remove code block tool calls first (most specific)
    |> String.replace(~r/```(?:json)?\s*\{[^`]+\}\s*```/s, "")
    # Remove text pattern tool calls
    |> String.replace(~r/\[TOOL_CALL:\s*\w+\s+\{[^\]]+\}\]/s, "")
    # Remove standalone JSON tool calls (use the balanced extraction)
    |> remove_tool_call_json()
    # Clean up extra whitespace
    |> String.trim()
  end

  defp remove_tool_call_json(text) do
    case find_json_object_containing(text, "tool_call") do
      nil ->
        text

      json_str ->
        # Remove this occurrence and check for more
        text
        |> String.replace(json_str, "", global: false)
        |> remove_tool_call_json()
    end
  end

  @doc """
  Checks if a response contains a tool call without fully parsing it.

  Faster than full parsing when you just need to know if a tool call exists.

  ## Examples

      iex> MCPResponseParser.contains_tool_call?(~s({"tool_call": {...}}))
      true

      iex> MCPResponseParser.contains_tool_call?("Normal response")
      false

  """
  @spec contains_tool_call?(String.t()) :: boolean()
  def contains_tool_call?(response_text) when is_binary(response_text) do
    String.contains?(response_text, "tool_call") or
      Regex.match?(~r/\[TOOL_CALL:/, response_text)
  end

  @doc """
  Parses multiple tool calls from a response (for chained tool usage).

  Some LLMs might request multiple tools in sequence or parallel.
  This function extracts all tool calls found in the response.

  ## Returns

    A list of `{:tool_call, name, args}` tuples

  ## Examples

      iex> text = ~s({"tool_call": {"name": "tool1", "arguments": {}}} {"tool_call": {"name": "tool2", "arguments": {}}})
      iex> MCPResponseParser.parse_multiple_tool_calls(text)
      [
        {:tool_call, "tool1", %{}},
        {:tool_call, "tool2", %{}}
      ]

  """
  @spec parse_multiple_tool_calls(String.t()) :: list(tool_call())
  def parse_multiple_tool_calls(response_text) when is_binary(response_text) do
    find_all_tool_calls(response_text, [])
  end

  defp find_all_tool_calls(text, acc) do
    case find_json_object_containing(text, "tool_call") do
      nil ->
        Enum.reverse(acc)

      json_str ->
        case parse_response(json_str) do
          {:tool_call, _name, _args} = tool_call ->
            # Find position and continue searching after this match
            case :binary.match(text, json_str) do
              {pos, len} ->
                remaining = String.slice(text, pos + len, String.length(text))
                find_all_tool_calls(remaining, [tool_call | acc])

              :nomatch ->
                Enum.reverse([tool_call | acc])
            end

          :no_tool_call ->
            # Skip this match and continue
            case :binary.match(text, json_str) do
              {pos, len} ->
                remaining = String.slice(text, pos + len, String.length(text))
                find_all_tool_calls(remaining, acc)

              :nomatch ->
                Enum.reverse(acc)
            end
        end
    end
  end

  @doc """
  Validates that tool arguments match the expected schema.

  Performs basic validation to ensure required parameters are present
  and types are roughly correct.

  ## Parameters

    - args: The arguments map from the tool call
    - schema: The tool's input schema

  ## Returns

    - `:ok` - If validation passes
    - `{:error, reason}` - If validation fails

  """
  @spec validate_arguments(map(), map()) :: :ok | {:error, String.t()}
  def validate_arguments(args, schema) when is_map(args) and is_map(schema) do
    required = Map.get(schema, "required", [])
    properties = Map.get(schema, "properties", %{})

    # Check required fields
    missing_required =
      Enum.filter(required, fn field ->
        not Map.has_key?(args, field)
      end)

    if missing_required != [] do
      {:error, "Missing required parameters: #{Enum.join(missing_required, ", ")}"}
    else
      # Basic type checking
      validate_types(args, properties)
    end
  end

  def validate_arguments(_args, _schema), do: :ok

  defp validate_types(args, properties) do
    errors =
      Enum.flat_map(args, fn {key, value} ->
        case Map.get(properties, key) do
          %{"type" => expected_type} ->
            if type_matches?(value, expected_type) do
              []
            else
              ["Parameter '#{key}' expected type '#{expected_type}' but got '#{type_of(value)}'"]
            end

          _ ->
            []
        end
      end)

    if errors != [] do
      {:error, Enum.join(errors, "; ")}
    else
      :ok
    end
  end

  defp type_matches?(value, "string"), do: is_binary(value)
  defp type_matches?(value, "number"), do: is_number(value)
  defp type_matches?(value, "integer"), do: is_integer(value)
  defp type_matches?(value, "boolean"), do: is_boolean(value)
  defp type_matches?(value, "array"), do: is_list(value)
  defp type_matches?(value, "object"), do: is_map(value)
  defp type_matches?(_value, _type), do: true

  defp type_of(value) when is_binary(value), do: "string"
  defp type_of(value) when is_integer(value), do: "integer"
  defp type_of(value) when is_float(value), do: "number"
  defp type_of(value) when is_boolean(value), do: "boolean"
  defp type_of(value) when is_list(value), do: "array"
  defp type_of(value) when is_map(value), do: "object"
  defp type_of(_value), do: "unknown"

  @doc """
  Formats a parse error for display to the user.

  Provides helpful error messages when tool call parsing fails.
  """
  @spec format_parse_error(term()) :: String.t()
  def format_parse_error(:no_tool_call) do
    "No tool call detected in response"
  end

  def format_parse_error({:error, reason}) when is_binary(reason) do
    "Tool call parsing error: #{reason}"
  end

  def format_parse_error(error) do
    "Tool call parsing error: #{inspect(error)}"
  end

  @doc """
  Extracts the tool name from a parsed tool call tuple.

  ## Examples

      iex> MCPResponseParser.extract_tool_name({:tool_call, "read_file", %{}})
      "read_file"

  """
  @spec extract_tool_name(tool_call()) :: String.t() | nil
  def extract_tool_name({:tool_call, name, _args}), do: name
  def extract_tool_name(_), do: nil

  @doc """
  Extracts the arguments from a parsed tool call tuple.

  ## Examples

      iex> MCPResponseParser.extract_arguments({:tool_call, "read_file", %{"path" => "test.txt"}})
      %{"path" => "test.txt"}

  """
  @spec extract_arguments(tool_call()) :: map() | nil
  def extract_arguments({:tool_call, _name, args}), do: args
  def extract_arguments(_), do: nil
end
