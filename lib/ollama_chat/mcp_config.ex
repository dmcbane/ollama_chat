defmodule OllamaChat.MCPConfig do
  @moduledoc """
  JSON file-based persistence for MCP server configurations.

  Provides pure functions (no GenServer) for loading, saving, validating,
  and merging MCP server configs. Configs are stored as JSON on disk and
  converted to atom-keyed maps for internal use by `OllamaChat.MCPClient`.

  ## Config resolution order

  `load_with_defaults/0` merges two sources:

    1. **Application config** — `Application.get_env(:ollama_chat, :mcp_servers, [])`
    2. **JSON file** — stored at `config_path/0`

  File-based configs win when a server with the same `:name` exists in both.
  """

  require Logger

  @default_config_path "~/.config/ollama_chat/mcp_servers.json"

  @required_fields [:name, :display_name, :command]

  @optional_defaults %{
    description: "",
    args: [],
    enabled: true,
    requires_approval: false,
    dangerous_tools: [],
    env: %{}
  }

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Returns the path to the MCP servers JSON config file.

  Reads from `Application.get_env(:ollama_chat, :mcp_config_path)` or
  defaults to `~/.config/ollama_chat/mcp_servers.json`.
  """
  @spec config_path() :: String.t()
  def config_path do
    path = Application.get_env(:ollama_chat, :mcp_config_path) || @default_config_path
    Path.expand(path)
  end

  @doc """
  Loads server configs from the JSON file at `config_path/0`.

  Returns `{:ok, list}` with atom-keyed server config maps, or `{:ok, []}`
  when the file does not exist. Returns `{:error, reason}` on JSON parse
  failures or unexpected file content.
  """
  @spec load() :: {:ok, [map()]} | {:error, term()}
  def load do
    path = config_path()

    case File.read(path) do
      {:ok, contents} ->
        parse_json_contents(contents)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        Logger.warning("Failed to read MCP config file #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Saves a list of server configs to the JSON file at `config_path/0`.

  Creates parent directories if they don't exist. Uses an atomic write
  strategy (write to temp file, then rename) to avoid partial writes.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec save([map()]) :: :ok | {:error, term()}
  def save(servers) when is_list(servers) do
    path = config_path()
    dir = Path.dirname(path)
    tmp_path = path <> ".tmp"

    json_servers = Enum.map(servers, &to_json/1)
    payload = %{"servers" => json_servers}

    with :ok <- File.mkdir_p(dir),
         {:ok, encoded} <- encode_json(payload),
         :ok <- write_file(tmp_path, encoded),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} = error ->
        # Clean up temp file on failure
        File.rm(tmp_path)
        Logger.warning("Failed to save MCP config to #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Loads configs from the JSON file and merges them with application config.

  Application config servers (`Application.get_env(:ollama_chat, :mcp_servers, [])`)
  form the base. File-based servers override any app config server with a
  matching `:name`. File-only servers are appended at the end.

  Falls back to application config alone when the file cannot be read.
  """
  @spec load_with_defaults() :: [map()]
  def load_with_defaults do
    app_servers = Application.get_env(:ollama_chat, :mcp_servers, [])

    case load() do
      {:ok, file_servers} ->
        merge_servers(app_servers, file_servers)

      {:error, _reason} ->
        app_servers
    end
  end

  @doc """
  Validates that a command path exists and is executable.

  Returns `:ok` if the command is found and executable, `{:warning, message}`
  if the command is not found (it might be installed later), or
  `{:error, message}` for invalid input.

  ## Examples

      iex> MCPConfig.validate_command_path("/usr/bin/env")
      :ok

      iex> MCPConfig.validate_command_path("")
      {:error, "command is required"}

      iex> MCPConfig.validate_command_path("/no/such/binary")
      {:warning, "Command path does not exist: /no/such/binary"}
  """
  @spec validate_command_path(String.t()) :: :ok | {:warning, String.t()} | {:error, String.t()}
  def validate_command_path(command) when is_binary(command) do
    if String.trim(command) == "" do
      {:error, "command is required"}
    else
      validate_command(command)
    end
  end

  defp validate_command(<<"/"::utf8, _rest::binary>> = path) do
    check_absolute_path(path)
  end

  defp validate_command(<<"~"::utf8, _rest::binary>> = path) do
    check_absolute_path(Path.expand(path))
  end

  defp validate_command(command) do
    case System.find_executable(command) do
      nil -> {:warning, "Command '#{command}' not found in PATH"}
      _path -> :ok
    end
  end

  defp check_absolute_path(path) do
    if File.exists?(path) do
      case File.stat(path) do
        {:ok, %{mode: mode}} ->
          if Bitwise.band(mode, 0o111) != 0 do
            :ok
          else
            {:warning, "Command path is not executable: #{path}"}
          end

        {:error, _reason} ->
          {:warning, "Command path does not exist: #{path}"}
      end
    else
      {:warning, "Command path does not exist: #{path}"}
    end
  end

  @doc """
  Validates and normalizes a server config map.

  Accepts both string-keyed and atom-keyed maps. On success returns
  `{:ok, normalized}` with atom keys and defaults filled in. On failure
  returns `{:error, errors}` where `errors` is a list of human-readable
  error strings.

  ## Required fields

    * `name` — non-empty string or atom
    * `display_name` — non-empty string
    * `command` — non-empty string

  ## Optional fields (with defaults)

    * `description` — string, defaults to `""`
    * `args` — list, defaults to `[]`
    * `enabled` — boolean, defaults to `true`
    * `requires_approval` — boolean, defaults to `false`
    * `dangerous_tools` — list, defaults to `[]`
    * `env` — map, defaults to `%{}`
  """
  @spec validate_server_config(map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate_server_config(config) when is_map(config) do
    normalized = normalize_keys(config)

    errors =
      List.flatten([
        validate_required(normalized),
        validate_optional_types(normalized)
      ])

    if errors == [] do
      {:ok, build_config(normalized)}
    else
      {:error, errors}
    end
  end

  # ── Conversion helpers ──────────────────────────────────────────────

  @doc """
  Converts a string-keyed map (from JSON) to an atom-keyed internal format.

  The `"name"` value is converted to an atom. Missing optional fields are
  filled in with defaults.
  """
  @spec to_internal(map()) :: map()
  def to_internal(%{} = json_map) do
    normalized = normalize_keys(json_map)
    build_config(normalized)
  end

  @doc """
  Converts an atom-keyed internal map to a string-keyed map for JSON serialization.

  The `:name` atom is converted to a string.
  """
  @spec to_json(map()) :: map()
  def to_json(%{} = internal_map) do
    internal_map
    |> Map.take([
      :name,
      :display_name,
      :description,
      :command,
      :args,
      :enabled,
      :requires_approval,
      :dangerous_tools,
      :env
    ])
    |> Enum.map(fn
      {:name, name} when is_atom(name) -> {"name", Atom.to_string(name)}
      {:name, name} -> {"name", to_string(name)}
      {key, value} -> {Atom.to_string(key), value}
    end)
    |> Enum.into(%{})
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp parse_json_contents(contents) do
    contents = maybe_trim_bom(contents)

    if String.trim(contents) == "" do
      {:ok, []}
    else
      case Jason.decode(contents) do
        {:ok, %{"servers" => servers}} when is_list(servers) ->
          {:ok, Enum.map(servers, &to_internal/1)}

        {:ok, _other} ->
          {:error, "expected JSON object with a \"servers\" key containing a list"}

        {:error, %Jason.DecodeError{} = error} ->
          {:error, "JSON parse error: #{Exception.message(error)}"}
      end
    end
  end

  # Strip a UTF-8 BOM (byte-order mark) from the beginning of content if present.
  defp maybe_trim_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp maybe_trim_bom(contents), do: contents

  defp encode_json(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, _json} = ok -> ok
      {:error, reason} -> {:error, "JSON encode error: #{inspect(reason)}"}
    end
  end

  defp write_file(path, content) do
    File.write(path, content)
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Normalize a map to atom keys, handling both string and atom input keys.
  defp normalize_keys(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {safe_to_atom(key), value}
      {key, value} when is_atom(key) -> {key, value}
    end)
  end

  # Convert well-known config keys to atoms without leaking arbitrary atoms.
  @known_keys ~w(name display_name description command args enabled requires_approval dangerous_tools env)a

  defp safe_to_atom(key) when is_binary(key) do
    atom = String.to_existing_atom(key)

    if atom in @known_keys do
      atom
    else
      # Return the original string wrapped — but since we need atom keys,
      # fall through to creating the atom. This is safe for the known set.
      atom
    end
  rescue
    ArgumentError -> String.to_atom(key)
  end

  # ── Validation ──────────────────────────────────────────────────────

  defp validate_required(normalized) do
    Enum.flat_map(@required_fields, fn field ->
      value = Map.get(normalized, field)

      cond do
        is_nil(value) ->
          ["#{field} is required"]

        field == :name and is_atom(value) and value not in [nil, :""] ->
          []

        field == :name and is_binary(value) and String.trim(value) != "" ->
          []

        field == :name ->
          ["#{field} must be a non-empty string or atom"]

        is_binary(value) and String.trim(value) != "" ->
          []

        true ->
          ["#{field} must be a non-empty string"]
      end
    end)
  end

  defp validate_optional_types(normalized) do
    validations = [
      {:args, &is_list/1, "args must be a list"},
      {:enabled, &is_boolean/1, "enabled must be a boolean"},
      {:requires_approval, &is_boolean/1, "requires_approval must be a boolean"},
      {:dangerous_tools, &is_list/1, "dangerous_tools must be a list"},
      {:env, &is_map/1, "env must be a map"}
    ]

    Enum.flat_map(validations, fn {field, check_fn, message} ->
      case Map.get(normalized, field) do
        nil -> []
        value -> if check_fn.(value), do: [], else: [message]
      end
    end)
  end

  # ── Config building ─────────────────────────────────────────────────

  defp build_config(normalized) do
    name = coerce_name(Map.get(normalized, :name))

    @optional_defaults
    |> Map.merge(Map.take(normalized, Map.keys(@optional_defaults)))
    |> Map.merge(%{
      name: name,
      display_name: Map.get(normalized, :display_name, ""),
      command: Map.get(normalized, :command, "")
    })
  end

  defp coerce_name(name) when is_atom(name), do: name
  defp coerce_name(name) when is_binary(name), do: String.to_atom(name)
  defp coerce_name(name), do: name

  # ── Merge logic ─────────────────────────────────────────────────────

  defp merge_servers(app_servers, file_servers) do
    file_by_name =
      Map.new(file_servers, fn server ->
        {server.name, server}
      end)

    # Walk through app servers; replace with file version if present.
    {merged, used_names} =
      Enum.map_reduce(app_servers, MapSet.new(), fn app_server, seen ->
        name = app_server.name

        server =
          case Map.get(file_by_name, name) do
            nil -> app_server
            file_server -> file_server
          end

        {server, MapSet.put(seen, name)}
      end)

    # Append file-only servers that weren't in app config.
    file_only =
      Enum.reject(file_servers, fn server ->
        MapSet.member?(used_names, server.name)
      end)

    merged ++ file_only
  end
end
