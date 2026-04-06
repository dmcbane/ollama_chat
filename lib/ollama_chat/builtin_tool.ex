defmodule OllamaChat.BuiltinTool do
  @moduledoc """
  Behaviour for tools that execute in-process (as opposed to MCP tools
  that execute via external server processes).

  Built-in tools are always available as long as their backing system
  (e.g. the memory database) is available. They are discovered at
  compile-time via `OllamaChat.BuiltinTools.Registry`.

  ## Implementing a Built-in Tool

      defmodule OllamaChat.BuiltinTools.Memory.Save do
        @behaviour OllamaChat.BuiltinTool

        @impl true
        def name, do: "memory_save"

        @impl true
        def description, do: "Save a memory about the user."

        @impl true
        def parameters_schema do
          %{
            "type" => "object",
            "required" => ["content"],
            "properties" => %{
              "content" => %{"type" => "string", "description" => "Memory content"}
            }
          }
        end

        @impl true
        def execute(%{"content" => content}) do
          {:ok, "Saved: \#{content}"}
        end
      end

  ## Return Values

  `execute/1` must return one of:

    - `{:ok, result_text}` — success; `result_text` is shown to the LLM as
      the tool result and may also be displayed in the UI.
    - `{:error, reason_text}` — failure; `reason_text` describes what went wrong.

  Both values are strings so the LLM can process them naturally.
  """

  @doc """
  The unique tool name used in LLM tool calls (e.g. `"memory_save"`).

  Must be a non-empty string containing only alphanumeric characters,
  underscores, and hyphens (`[a-zA-Z0-9_-]+`).
  """
  @callback name() :: String.t()

  @doc """
  A human-readable description of what the tool does.

  This is shown to the LLM in the system prompt so it can decide when to
  call the tool. Keep it concise but precise.
  """
  @callback description() :: String.t()

  @doc """
  JSON Schema object describing the tool's accepted parameters.

  The schema must be a map with at least `"type" => "object"` and a
  `"properties"` key. Required parameters should be listed in `"required"`.

  Example:

      %{
        "type" => "object",
        "required" => ["content"],
        "properties" => %{
          "content" => %{
            "type" => "string",
            "description" => "The memory content to save"
          }
        }
      }

  """
  @callback parameters_schema() :: map()

  @doc """
  Executes the tool with the given arguments.

  `args` is a string-keyed map decoded from the JSON the LLM produced.

  Returns `{:ok, result_text}` on success or `{:error, reason_text}` on
  failure. Both branches produce a plain string so the LLM can process the
  tool result naturally.
  """
  @callback execute(args :: map()) :: {:ok, String.t()} | {:error, String.t()}
end
