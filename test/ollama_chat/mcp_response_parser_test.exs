defmodule OllamaChat.MCPResponseParserTest do
  use ExUnit.Case, async: true

  alias OllamaChat.MCPResponseParser

  describe "parse_response/1" do
    test "parses direct JSON tool call" do
      json = ~s({"tool_call": {"name": "read_file", "arguments": {"path": "test.txt"}}})

      assert {:tool_call, "read_file", %{"path" => "test.txt"}} =
               MCPResponseParser.parse_response(json)
    end

    test "parses tool call with complex arguments" do
      json =
        ~s({"tool_call": {"name": "search", "arguments": {"query": "elixir", "limit": 10, "filter": {"date": "2024"}}}})

      assert {:tool_call, "search", args} = MCPResponseParser.parse_response(json)
      assert args["query"] == "elixir"
      assert args["limit"] == 10
      assert args["filter"]["date"] == "2024"
    end

    test "parses tool call from JSON code block" do
      text = """
      Here's what I'll do:
      ```json
      {"tool_call": {"name": "write_file", "arguments": {"path": "output.txt", "content": "hello"}}}
      ```
      """

      assert {:tool_call, "write_file", %{"path" => "output.txt", "content" => "hello"}} =
               MCPResponseParser.parse_response(text)
    end

    test "parses tool call from code block without json marker" do
      text = """
      ```
      {"tool_call": {"name": "get_time", "arguments": {}}}
      ```
      """

      assert {:tool_call, "get_time", %{}} = MCPResponseParser.parse_response(text)
    end

    test "parses tool call from text pattern [TOOL_CALL: name args]" do
      text = ~s([TOOL_CALL: read_file {"path": "config.json"}])

      assert {:tool_call, "read_file", %{"path" => "config.json"}} =
               MCPResponseParser.parse_response(text)
    end

    test "returns :no_tool_call for normal text" do
      text = "This is just a normal response without any tool calls."

      assert :no_tool_call = MCPResponseParser.parse_response(text)
    end

    test "returns :no_tool_call for invalid JSON" do
      text = ~s({"invalid": "json})

      assert :no_tool_call = MCPResponseParser.parse_response(text)
    end

    test "returns :no_tool_call for JSON without tool_call" do
      text = ~s({"response": "This is a regular JSON response"})

      assert :no_tool_call = MCPResponseParser.parse_response(text)
    end

    test "returns :no_tool_call for malformed tool call" do
      text = ~s({"tool_call": "invalid_format"})

      assert :no_tool_call = MCPResponseParser.parse_response(text)
    end

    test "validates tool name contains only valid characters" do
      # Valid characters: alphanumeric, underscore, hyphen
      json = ~s({"tool_call": {"name": "read-file_v2", "arguments": {}}})

      assert {:tool_call, "read-file_v2", %{}} = MCPResponseParser.parse_response(json)
    end

    test "rejects tool names with invalid characters" do
      json = ~s({"tool_call": {"name": "read file!", "arguments": {}}})

      assert :no_tool_call = MCPResponseParser.parse_response(json)
    end

    test "handles empty string" do
      assert :no_tool_call = MCPResponseParser.parse_response("")
    end

    test "handles nil input" do
      assert :no_tool_call = MCPResponseParser.parse_response(nil)
    end

    test "handles whitespace-only input" do
      assert :no_tool_call = MCPResponseParser.parse_response("   \n\t  ")
    end
  end

  describe "strip_tool_call/1" do
    test "removes JSON tool call from response" do
      text = ~s({"tool_call": {"name": "read_file", "arguments": {"path": "test.txt"}}})

      result = MCPResponseParser.strip_tool_call(text)

      assert result == ""
    end

    test "removes tool call but keeps surrounding text" do
      text = """
      I'll read that file for you.
      {"tool_call": {"name": "read_file", "arguments": {"path": "test.txt"}}}
      Please wait...
      """

      result = MCPResponseParser.strip_tool_call(text)

      assert result =~ "I'll read that file for you"
      assert result =~ "Please wait"
      refute result =~ "tool_call"
    end

    test "removes code block tool calls" do
      text = """
      Let me check that:
      ```json
      {"tool_call": {"name": "get_time", "arguments": {}}}
      ```
      """

      result = MCPResponseParser.strip_tool_call(text)

      assert result =~ "Let me check that"
      refute result =~ "tool_call"
      refute result =~ "```"
    end

    test "removes text pattern tool calls" do
      text = "I'll use [TOOL_CALL: read_file {\"path\": \"test.txt\"}] to get that information."

      result = MCPResponseParser.strip_tool_call(text)

      assert result =~ "I'll use"
      assert result =~ "to get that information"
      refute result =~ "TOOL_CALL"
    end

    test "returns text unchanged if no tool call present" do
      text = "This is a normal response."

      result = MCPResponseParser.strip_tool_call(text)

      assert result == text
    end

    test "handles multiple tool calls in one response" do
      text = """
      {"tool_call": {"name": "tool1", "arguments": {}}}
      Some text
      {"tool_call": {"name": "tool2", "arguments": {}}}
      """

      result = MCPResponseParser.strip_tool_call(text)

      refute result =~ "tool_call"
      assert result =~ "Some text"
    end
  end

  describe "contains_tool_call?/1" do
    test "returns true for JSON tool call" do
      text = ~s({"tool_call": {"name": "read_file", "arguments": {}}})

      assert MCPResponseParser.contains_tool_call?(text)
    end

    test "returns true for text pattern tool call" do
      text = "[TOOL_CALL: read_file {}]"

      assert MCPResponseParser.contains_tool_call?(text)
    end

    test "returns false for normal text" do
      text = "This is a normal response."

      refute MCPResponseParser.contains_tool_call?(text)
    end

    test "returns false for empty string" do
      refute MCPResponseParser.contains_tool_call?("")
    end
  end

  describe "parse_multiple_tool_calls/1" do
    test "parses multiple tool calls from response" do
      text = """
      {"tool_call": {"name": "tool1", "arguments": {"arg1": "value1"}}}
      {"tool_call": {"name": "tool2", "arguments": {"arg2": "value2"}}}
      """

      result = MCPResponseParser.parse_multiple_tool_calls(text)

      assert length(result) == 2
      assert {:tool_call, "tool1", %{"arg1" => "value1"}} in result
      assert {:tool_call, "tool2", %{"arg2" => "value2"}} in result
    end

    test "returns empty list when no tool calls present" do
      text = "Normal response without tool calls"

      result = MCPResponseParser.parse_multiple_tool_calls(text)

      assert result == []
    end

    test "handles single tool call" do
      text = ~s({"tool_call": {"name": "read_file", "arguments": {}}})

      result = MCPResponseParser.parse_multiple_tool_calls(text)

      assert length(result) == 1
      assert {:tool_call, "read_file", %{}} = hd(result)
    end

    test "filters out invalid tool calls" do
      text = """
      {"tool_call": {"name": "valid_tool", "arguments": {}}}
      {"tool_call": "invalid"}
      {"tool_call": {"name": "another_valid", "arguments": {}}}
      """

      result = MCPResponseParser.parse_multiple_tool_calls(text)

      assert length(result) == 2
    end
  end

  describe "validate_arguments/2" do
    test "validates arguments with required fields present" do
      args = %{"path" => "/test/file.txt"}

      schema = %{
        "required" => ["path"],
        "properties" => %{
          "path" => %{"type" => "string"}
        }
      }

      assert :ok = MCPResponseParser.validate_arguments(args, schema)
    end

    test "returns error when required field is missing" do
      args = %{}

      schema = %{
        "required" => ["path"],
        "properties" => %{
          "path" => %{"type" => "string"}
        }
      }

      assert {:error, message} = MCPResponseParser.validate_arguments(args, schema)
      assert message =~ "Missing required parameters"
      assert message =~ "path"
    end

    test "validates type matching for string" do
      args = %{"name" => "test"}

      schema = %{
        "properties" => %{
          "name" => %{"type" => "string"}
        }
      }

      assert :ok = MCPResponseParser.validate_arguments(args, schema)
    end

    test "returns error for type mismatch" do
      args = %{"count" => "not a number"}

      schema = %{
        "properties" => %{
          "count" => %{"type" => "number"}
        }
      }

      assert {:error, message} = MCPResponseParser.validate_arguments(args, schema)
      assert message =~ "expected type 'number'"
      assert message =~ "got 'string'"
    end

    test "validates integer type" do
      args = %{"count" => 42}

      schema = %{
        "properties" => %{
          "count" => %{"type" => "integer"}
        }
      }

      assert :ok = MCPResponseParser.validate_arguments(args, schema)
    end

    test "validates boolean type" do
      args = %{"enabled" => true}

      schema = %{
        "properties" => %{
          "enabled" => %{"type" => "boolean"}
        }
      }

      assert :ok = MCPResponseParser.validate_arguments(args, schema)
    end

    test "validates array type" do
      args = %{"items" => ["a", "b", "c"]}

      schema = %{
        "properties" => %{
          "items" => %{"type" => "array"}
        }
      }

      assert :ok = MCPResponseParser.validate_arguments(args, schema)
    end

    test "validates object type" do
      args = %{"config" => %{"key" => "value"}}

      schema = %{
        "properties" => %{
          "config" => %{"type" => "object"}
        }
      }

      assert :ok = MCPResponseParser.validate_arguments(args, schema)
    end

    test "allows extra arguments not in schema" do
      args = %{"path" => "/test", "extra" => "value"}

      schema = %{
        "required" => ["path"],
        "properties" => %{
          "path" => %{"type" => "string"}
        }
      }

      assert :ok = MCPResponseParser.validate_arguments(args, schema)
    end

    test "returns ok for empty schema" do
      args = %{"anything" => "goes"}
      schema = %{}

      assert :ok = MCPResponseParser.validate_arguments(args, schema)
    end

    test "handles multiple validation errors" do
      args = %{"name" => 123, "count" => "not_a_number"}

      schema = %{
        "properties" => %{
          "name" => %{"type" => "string"},
          "count" => %{"type" => "integer"}
        }
      }

      assert {:error, message} = MCPResponseParser.validate_arguments(args, schema)
      assert message =~ "name"
      assert message =~ "count"
    end
  end

  describe "format_parse_error/1" do
    test "formats :no_tool_call error" do
      message = MCPResponseParser.format_parse_error(:no_tool_call)

      assert message == "No tool call detected in response"
    end

    test "formats string error" do
      message = MCPResponseParser.format_parse_error({:error, "Custom error message"})

      assert message =~ "Custom error message"
    end

    test "formats unknown error" do
      message = MCPResponseParser.format_parse_error({:error, :unknown})

      assert message =~ "parsing error"
    end
  end

  describe "extract_tool_name/1" do
    test "extracts tool name from parsed tool call" do
      tool_call = {:tool_call, "read_file", %{}}

      assert "read_file" = MCPResponseParser.extract_tool_name(tool_call)
    end

    test "returns nil for invalid input" do
      assert nil == MCPResponseParser.extract_tool_name(:no_tool_call)
      assert nil == MCPResponseParser.extract_tool_name("invalid")
      assert nil == MCPResponseParser.extract_tool_name(nil)
    end
  end

  describe "extract_arguments/1" do
    test "extracts arguments from parsed tool call" do
      tool_call = {:tool_call, "read_file", %{"path" => "test.txt"}}

      assert %{"path" => "test.txt"} = MCPResponseParser.extract_arguments(tool_call)
    end

    test "returns nil for invalid input" do
      assert nil == MCPResponseParser.extract_arguments(:no_tool_call)
      assert nil == MCPResponseParser.extract_arguments("invalid")
      assert nil == MCPResponseParser.extract_arguments(nil)
    end

    test "returns empty map for tool call with no arguments" do
      tool_call = {:tool_call, "get_time", %{}}

      assert %{} = MCPResponseParser.extract_arguments(tool_call)
    end
  end

  describe "edge cases" do
    test "handles nested JSON in arguments" do
      json =
        ~s({"tool_call": {"name": "complex", "arguments": {"config": {"nested": {"deep": "value"}}}}})

      assert {:tool_call, "complex", args} = MCPResponseParser.parse_response(json)
      assert args["config"]["nested"]["deep"] == "value"
    end

    test "handles unicode in tool call" do
      json = ~s({"tool_call": {"name": "translate", "arguments": {"text": "Hello 世界"}}})

      assert {:tool_call, "translate", %{"text" => "Hello 世界"}} =
               MCPResponseParser.parse_response(json)
    end

    test "handles very long responses" do
      long_text = String.duplicate("a", 10_000)
      json = ~s({"tool_call": {"name": "process", "arguments": {"text": "#{long_text}"}}})

      assert {:tool_call, "process", %{"text" => ^long_text}} =
               MCPResponseParser.parse_response(json)
    end

    test "handles tool call embedded in larger response" do
      text = """
      I'll help you with that. Let me read the file.

      {"tool_call": {"name": "read_file", "arguments": {"path": "test.txt"}}}

      Once I get the results, I'll show you the contents.
      """

      assert {:tool_call, "read_file", %{"path" => "test.txt"}} =
               MCPResponseParser.parse_response(text)
    end

    test "prefers first valid tool call when multiple present" do
      text = """
      {"tool_call": {"name": "first_tool", "arguments": {}}}
      {"tool_call": {"name": "second_tool", "arguments": {}}}
      """

      # parse_response returns first valid match
      assert {:tool_call, "first_tool", %{}} = MCPResponseParser.parse_response(text)
    end
  end
end
