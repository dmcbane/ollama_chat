defmodule OllamaChat.PathGuard do
  @moduledoc """
  Validates that filesystem paths are confined to a workspace root directory.

  Used by `OllamaChat.MCPClient` to enforce path restrictions on MCP tool calls
  when a server has a `:root_path` configured.
  """

  @doc """
  Validates that `path` is within `root`.

  Handles:
  - Absolute paths (`/etc/passwd` → checked against root)
  - `~` expansion (`~/secret` → expanded, then checked)
  - Relative paths resolved relative to root
  - `..` traversal that escapes root (`../../etc` → rejected)
  - The root itself is considered valid

  Returns `{:ok, absolute_path}` on success, `{:error, reason_string}` on failure.
  """
  @spec validate_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_path(path, root) when is_binary(path) and is_binary(root) do
    abs_root = Path.expand(root)
    abs_path = expand_path(path, abs_root)

    if within_root?(abs_path, abs_root) do
      {:ok, abs_path}
    else
      {:error, "Path #{inspect(path)} is outside the workspace root #{inspect(abs_root)}"}
    end
  end

  @doc """
  Checks all "path-like" string values in the args map against `root`.

  A value is path-like if it:
  - Starts with `/` (absolute)
  - Starts with `~` (home-relative)
  - Starts with `..` (explicit traversal)
  - Contains `/` (relative with subdirs)
  - Contains `\\` (Windows-style, treated as path separator)

  Plain filenames like `"README.md"` or `"file.txt"` (no slashes, not `..`) are
  NOT treated as path-like and pass through unchanged, because they will safely
  resolve under the root when the MCP server processes them.

  Returns `{:ok, args}` (unchanged) on success, `{:error, reason_string}` on failure.
  The `reason_string` includes the arg key name and the problematic path value.
  """
  @spec sanitize_args(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def sanitize_args(args, root) when is_map(args) and is_binary(root) do
    result =
      Enum.reduce_while(args, :ok, fn {key, value}, _acc ->
        if is_binary(value) and path_like?(value) do
          case validate_path(value, root) do
            {:ok, _} ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, "arg #{inspect(key)}: #{reason}"}}
          end
        else
          {:cont, :ok}
        end
      end)

    case result do
      :ok -> {:ok, args}
      {:error, _} = error -> error
    end
  end

  # Expands a path to an absolute path.
  # Absolute paths and `~`-prefixed paths are expanded with Path.expand/1.
  # Relative paths are expanded relative to the given root with Path.expand/2.
  defp expand_path(path, root) do
    if String.starts_with?(path, "/") or String.starts_with?(path, "~") do
      Path.expand(path)
    else
      Path.expand(path, root)
    end
  end

  # Returns true if abs_path is equal to abs_root or is a direct descendant of it.
  # The trailing-slash trick prevents prefix false-positives, e.g.
  # "/root-other" must NOT match root "/root".
  defp within_root?(abs_path, abs_root) do
    String.starts_with?(abs_path <> "/", abs_root <> "/")
  end

  # Returns true if the value looks like a filesystem path that needs validation.
  # Plain filenames (no slashes, no leading special chars) are not path-like and
  # are left for the MCP server to resolve safely under its own working directory.
  defp path_like?(value) do
    String.starts_with?(value, "/") or
      String.starts_with?(value, "~") or
      String.starts_with?(value, "..") or
      value == "." or
      String.contains?(value, "/") or
      String.contains?(value, "\\")
  end
end
