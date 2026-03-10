defmodule OllamaChat.MCPPromptBuilderTest do
  use ExUnit.Case, async: true

  alias OllamaChat.MCPPromptBuilder

  describe "build_tool_aware_system_prompt/2" do
    test "builds prompt with single tool" do
      tools = %{
        "read_file" => %{
          description: "Read a file's contents",
          schema: %{
            "properties" => %{
              "path" => %{"type" => "string", "description" => "Path to the file"}
            },
            "required" => ["path"]
          },
          requires_approval: false
        }
      }

      prompt = MCPPromptBuilder.build_tool_aware_system_prompt(tools)

      assert prompt =~ "AI assistant with access to external tools"
      assert prompt =~ "read_file"
      assert prompt =~ "Read a file's contents"
      assert prompt =~ "path (string) (required)"
      assert prompt =~ "tool_call"
    end

    test "builds prompt with multiple tools" do
      tools = %{
        "read_file" => %{
          description: "Read a file",
          schema: %{"properties" => %{}},
          requires_approval: false
        },
        "write_file" => %{
          description: "Write a file",
          schema: %{"properties" => %{}},
          requires_approval: true
        }
      }

      prompt = MCPPromptBuilder.build_tool_aware_system_prompt(tools)

      assert prompt =~ "read_file"
      assert prompt =~ "write_file"
      assert prompt =~ "requires user approval"
    end

    test "returns standard prompt when no tools available" do
      tools = %{}
      prompt = MCPPromptBuilder.build_tool_aware_system_prompt(tools)

      assert prompt =~ "helpful AI assistant"
      refute prompt =~ "Available Tools"
    end

    test "includes base prompt when provided" do
      tools = %{}
      base_prompt = "You are a specialized assistant."

      prompt = MCPPromptBuilder.build_tool_aware_system_prompt(tools, base_prompt)

      assert prompt == base_prompt
    end

    test "prepends base prompt to tool instructions" do
      tools = %{
        "test_tool" => %{
          description: "Test tool",
          schema: %{"properties" => %{}},
          requires_approval: false
        }
      }

      base_prompt = "You are a specialized assistant."

      prompt = MCPPromptBuilder.build_tool_aware_system_prompt(tools, base_prompt)

      assert prompt =~ base_prompt
      assert prompt =~ "test_tool"
    end

    test "formats optional parameters correctly" do
      tools = %{
        "search" => %{
          description: "Search for something",
          schema: %{
            "properties" => %{
              "query" => %{"type" => "string", "description" => "Search query"},
              "limit" => %{"type" => "integer", "description" => "Max results"}
            },
            "required" => ["query"]
          },
          requires_approval: false
        }
      }

      prompt = MCPPromptBuilder.build_tool_aware_system_prompt(tools)

      assert prompt =~ "query (string) (required)"
      assert prompt =~ "limit (integer) (optional)"
    end

    test "handles tools with no parameters" do
      tools = %{
        "get_time" => %{
          description: "Get current time",
          schema: %{},
          requires_approval: false
        }
      }

      prompt = MCPPromptBuilder.build_tool_aware_system_prompt(tools)

      assert prompt =~ "get_time"
      assert prompt =~ "no parameters required"
    end
  end

  describe "build_standard_system_prompt/1" do
    test "returns default prompt when no base prompt provided" do
      prompt = MCPPromptBuilder.build_standard_system_prompt()

      assert prompt =~ "helpful AI assistant"
    end

    test "returns base prompt when provided" do
      base_prompt = "Custom prompt"
      prompt = MCPPromptBuilder.build_standard_system_prompt(base_prompt)

      assert prompt == base_prompt
    end
  end

  describe "build_tool_result_message/2" do
    test "formats text result" do
      result = [
        %{"type" => "text", "text" => "File contents here"}
      ]

      message = MCPPromptBuilder.build_tool_result_message("read_file", result)

      assert message =~ "read_file"
      assert message =~ "File contents here"
      assert message =~ "continue your response"
    end

    test "formats multiple text results" do
      result = [
        %{"type" => "text", "text" => "Part 1"},
        %{"type" => "text", "text" => "Part 2"}
      ]

      message = MCPPromptBuilder.build_tool_result_message("test_tool", result)

      assert message =~ "Part 1"
      assert message =~ "Part 2"
    end

    test "formats image result" do
      result = [
        %{"type" => "image", "data" => "base64...", "mimeType" => "image/png"}
      ]

      message = MCPPromptBuilder.build_tool_result_message("screenshot", result)

      assert message =~ "[Image: image/png]"
    end

    test "formats resource result" do
      result = [
        %{"type" => "resource", "uri" => "file:///path/to/file"}
      ]

      message = MCPPromptBuilder.build_tool_result_message("get_resource", result)

      assert message =~ "[Resource: file:///path/to/file]"
    end

    test "handles mixed result types" do
      result = [
        %{"type" => "text", "text" => "Some text"},
        %{"type" => "image", "data" => "...", "mimeType" => "image/jpeg"}
      ]

      message = MCPPromptBuilder.build_tool_result_message("complex_tool", result)

      assert message =~ "Some text"
      assert message =~ "[Image: image/jpeg]"
    end
  end

  describe "has_tool_instructions?/1" do
    test "returns true when prompt contains tool instructions" do
      prompt = "Some text\n\n## Available Tools:\n\ntest_tool"

      assert MCPPromptBuilder.has_tool_instructions?(prompt)
    end

    test "returns true when prompt contains tool_call" do
      prompt = "Use tool_call format"

      assert MCPPromptBuilder.has_tool_instructions?(prompt)
    end

    test "returns false for standard prompt" do
      prompt = "You are a helpful assistant"

      refute MCPPromptBuilder.has_tool_instructions?(prompt)
    end
  end

  describe "build_approval_notice/1" do
    test "builds notice for dangerous tool" do
      notice = MCPPromptBuilder.build_approval_notice("delete_file")

      assert notice =~ "delete_file"
      assert notice =~ "requires user approval"
    end
  end

  describe "build_tool_summary/1" do
    test "returns message for no tools" do
      summary = MCPPromptBuilder.build_tool_summary(%{})

      assert summary == "No tools available"
    end

    test "returns message for single tool" do
      tools = %{"read_file" => %{}}
      summary = MCPPromptBuilder.build_tool_summary(tools)

      assert summary =~ "1 tool available"
      assert summary =~ "read_file"
    end

    test "returns message for multiple tools (3 or less)" do
      tools = %{
        "tool1" => %{},
        "tool2" => %{},
        "tool3" => %{}
      }

      summary = MCPPromptBuilder.build_tool_summary(tools)

      assert summary =~ "3 tools available"
      assert summary =~ "tool1"
      assert summary =~ "tool2"
      assert summary =~ "tool3"
    end

    test "returns message for many tools (more than 3)" do
      tools = %{
        "tool1" => %{},
        "tool2" => %{},
        "tool3" => %{},
        "tool4" => %{},
        "tool5" => %{}
      }

      summary = MCPPromptBuilder.build_tool_summary(tools)

      assert summary =~ "5 tools available"
      assert summary =~ "and 2 more"
    end
  end

  describe "get_tool_name/1" do
    test "extracts tool name from tool info" do
      tool_info = %{name: "read_file", description: "Test"}

      assert MCPPromptBuilder.get_tool_name(tool_info) == "read_file"
    end

    test "returns unknown for tool info without name" do
      tool_info = %{description: "Test"}

      assert MCPPromptBuilder.get_tool_name(tool_info) == "unknown"
    end
  end
end
