defmodule McpTestServer.Servers.System do
  @moduledoc """
  MCP server providing BEAM VM monitoring, environment variable inspection,
  and general utility tools (time, random, hashing, echo).
  """

  @behaviour McpTestServer.ServerBehaviour

  @impl true
  def server_name, do: "mcp-system"

  @impl true
  def list_tools do
    [
      # Utility tools
      %{
        name: "echo",
        description: "Echo back the provided text (useful for testing)",
        inputSchema: %{
          type: "object",
          properties: %{
            text: %{type: "string", description: "Text to echo back"}
          },
          required: ["text"]
        }
      },
      %{
        name: "get_time",
        description: "Get the current date and time",
        inputSchema: %{
          type: "object",
          properties: %{
            timezone: %{
              type: "string",
              description: "Timezone name (informational only; server always returns UTC)",
              default: "UTC"
            }
          }
        }
      },
      %{
        name: "random_number",
        description: "Generate a random integer within a range",
        inputSchema: %{
          type: "object",
          properties: %{
            min: %{type: "integer", description: "Minimum value (inclusive)", default: 1},
            max: %{type: "integer", description: "Maximum value (inclusive)", default: 100}
          }
        }
      },
      %{
        name: "hash_text",
        description: "Compute a cryptographic hash of text",
        inputSchema: %{
          type: "object",
          properties: %{
            text: %{type: "string", description: "Text to hash"},
            algorithm: %{
              type: "string",
              description: "Hash algorithm: md5, sha256, or sha512",
              default: "sha256",
              enum: ["md5", "sha256", "sha512"]
            }
          },
          required: ["text"]
        }
      },
      # Environment tools
      %{
        name: "list_env",
        description: "List environment variables, with optional substring filter",
        inputSchema: %{
          type: "object",
          properties: %{
            filter: %{
              type: "string",
              description: "Optional substring to filter variable names (case-insensitive)"
            }
          }
        }
      },
      %{
        name: "get_env",
        description: "Get the value of a specific environment variable",
        inputSchema: %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Environment variable name"}
          },
          required: ["name"]
        }
      },
      # BEAM monitoring tools
      %{
        name: "beam_memory",
        description: "Get BEAM VM memory usage breakdown",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "beam_processes",
        description: "List information about BEAM processes",
        inputSchema: %{
          type: "object",
          properties: %{
            limit: %{
              type: "integer",
              description: "Maximum number of processes to return",
              default: 20
            },
            sort_by: %{
              type: "string",
              description: "Sort processes by: memory, reductions, message_queue",
              default: "memory",
              enum: ["memory", "reductions", "message_queue"]
            }
          }
        }
      },
      %{
        name: "beam_system_info",
        description: "Get BEAM VM system information",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "beam_schedulers",
        description: "Get BEAM scheduler count and utilization (1-second sample)",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "beam_applications",
        description: "List loaded OTP applications",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "beam_ets_tables",
        description: "List ETS (Erlang Term Storage) tables",
        inputSchema: %{
          type: "object",
          properties: %{
            limit: %{
              type: "integer",
              description: "Maximum number of tables to return (sorted by memory usage)",
              default: 20
            }
          }
        }
      }
    ]
  end

  @impl true
  def execute_tool(tool_name, arguments) do
    case tool_name do
      "echo" -> handle_echo(arguments)
      "get_time" -> handle_get_time(arguments)
      "random_number" -> handle_random_number(arguments)
      "hash_text" -> handle_hash_text(arguments)
      "list_env" -> handle_list_env(arguments)
      "get_env" -> handle_get_env(arguments)
      "beam_memory" -> handle_beam_memory(arguments)
      "beam_processes" -> handle_beam_processes(arguments)
      "beam_system_info" -> handle_beam_system_info(arguments)
      "beam_schedulers" -> handle_beam_schedulers(arguments)
      "beam_applications" -> handle_beam_applications(arguments)
      "beam_ets_tables" -> handle_beam_ets_tables(arguments)
      _ -> %{isError: true, content: [%{type: "text", text: "Unknown tool: #{tool_name}"}]}
    end
  end

  # Utility Handlers

  defp handle_echo(%{"text" => text}) do
    %{content: [%{type: "text", text: text}]}
  end

  defp handle_get_time(args) do
    timezone = Map.get(args, "timezone", "UTC")
    now = DateTime.utc_now()

    time_info = """
    Current Time (#{timezone}):
    #{DateTime.to_string(now)}

    Unix timestamp: #{DateTime.to_unix(now)}
    ISO 8601: #{DateTime.to_iso8601(now)}
    """

    %{content: [%{type: "text", text: time_info}]}
  end

  defp handle_random_number(args) do
    min = Map.get(args, "min", 1)
    max = Map.get(args, "max", 100)

    if min > max do
      %{isError: true, content: [%{type: "text", text: "min must be <= max"}]}
    else
      number = Enum.random(min..max)
      %{content: [%{type: "text", text: "Random number between #{min} and #{max}: #{number}"}]}
    end
  end

  defp handle_hash_text(%{"text" => text} = args) do
    algorithm = Map.get(args, "algorithm", "sha256")

    hash =
      case algorithm do
        "md5" -> :crypto.hash(:md5, text) |> Base.encode16(case: :lower)
        "sha256" -> :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
        "sha512" -> :crypto.hash(:sha512, text) |> Base.encode16(case: :lower)
        _ -> nil
      end

    if hash do
      %{content: [%{type: "text", text: "#{String.upcase(algorithm)} hash:\n#{hash}"}]}
    else
      %{isError: true, content: [%{type: "text", text: "Unsupported algorithm: #{algorithm}"}]}
    end
  end

  # Environment Handlers

  defp handle_list_env(args) do
    filter = Map.get(args, "filter")

    env_vars =
      System.get_env()
      |> Enum.filter(fn {key, _value} ->
        if filter,
          do: String.contains?(String.downcase(key), String.downcase(filter)),
          else: true
      end)
      |> Enum.sort()

    result_text =
      if Enum.empty?(env_vars) do
        if filter,
          do: "No environment variables matching filter: #{filter}",
          else: "No environment variables found"
      else
        count = length(env_vars)

        header =
          if filter,
            do: "Environment variables matching '#{filter}' (#{count}):",
            else: "Environment variables (#{count}):"

        vars_text =
          Enum.map_join(env_vars, "\n", fn {key, value} ->
            display_value =
              if String.length(value) > 100,
                do: String.slice(value, 0, 97) <> "...",
                else: value

            "#{key}=#{display_value}"
          end)

        "#{header}\n\n#{vars_text}"
      end

    %{content: [%{type: "text", text: result_text}]}
  end

  defp handle_get_env(%{"name" => name}) do
    case System.get_env(name) do
      nil ->
        %{isError: true, content: [%{type: "text", text: "Environment variable not found: #{name}"}]}

      value ->
        %{content: [%{type: "text", text: "#{name}=#{value}"}]}
    end
  end

  # BEAM Monitoring Handlers

  defp handle_beam_memory(_args) do
    memory = :erlang.memory()

    mb = fn bytes -> Float.round(bytes / 1_048_576, 2) end

    result_text = """
    BEAM VM Memory Usage:

    Total:            #{mb.(memory[:total])} MB
    Processes:        #{mb.(memory[:processes])} MB (used: #{mb.(memory[:processes_used])} MB)
    System:           #{mb.(memory[:system])} MB
    Atoms:            #{mb.(memory[:atom])} MB
    Binaries:         #{mb.(memory[:binary])} MB
    Code:             #{mb.(memory[:code])} MB
    ETS:              #{mb.(memory[:ets])} MB

    Raw bytes:
    Total:            #{memory[:total]} bytes
    Processes:        #{memory[:processes]} bytes
    System:           #{memory[:system]} bytes
    """

    %{content: [%{type: "text", text: result_text}]}
  end

  defp handle_beam_processes(args) do
    limit = Map.get(args, "limit", 20)
    sort_by = Map.get(args, "sort_by", "memory")

    processes =
      Process.list()
      |> Enum.map(fn pid ->
        info =
          Process.info(pid, [
            :memory,
            :reductions,
            :message_queue_len,
            :registered_name,
            :current_function
          ])

        case info do
          nil ->
            nil

          data ->
            %{
              pid: inspect(pid),
              memory: data[:memory] || 0,
              reductions: data[:reductions] || 0,
              message_queue: data[:message_queue_len] || 0,
              name: data[:registered_name] || :unnamed,
              current_function: format_function(data[:current_function])
            }
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> then(fn procs ->
        case sort_by do
          "memory" -> Enum.sort_by(procs, & &1.memory, :desc)
          "reductions" -> Enum.sort_by(procs, & &1.reductions, :desc)
          "message_queue" -> Enum.sort_by(procs, & &1.message_queue, :desc)
          _ -> procs
        end
      end)
      |> Enum.take(limit)

    result_text =
      if Enum.empty?(processes) do
        "No processes found"
      else
        header = "Top #{length(processes)} processes (sorted by #{sort_by}):\n\n"

        procs_text =
          Enum.map_join(processes, "\n\n", fn proc ->
            mem_kb = Float.round(proc.memory / 1024, 2)
            name_str = if proc.name == :unnamed, do: "", else: " (#{proc.name})"
            "PID: #{proc.pid}#{name_str}\n  Memory: #{mem_kb} KB\n  Reductions: #{proc.reductions}\n  Message Queue: #{proc.message_queue}\n  Current: #{proc.current_function}"
          end)

        header <> procs_text
      end

    %{content: [%{type: "text", text: result_text}]}
  end

  defp handle_beam_system_info(_args) do
    info = %{
      otp_release: :erlang.system_info(:otp_release),
      version: :erlang.system_info(:version),
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      logical_processors: :erlang.system_info(:logical_processors),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      port_limit: :erlang.system_info(:port_limit),
      ets_limit: :erlang.system_info(:ets_limit),
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit)
    }

    result_text = """
    BEAM VM System Information:

    OTP Release:           #{info.otp_release}
    ERTS Version:          #{info.version}

    Schedulers:
      Total:               #{info.schedulers}
      Online:              #{info.schedulers_online}
      Logical Processors:  #{info.logical_processors || "unknown"}

    Processes:
      Current:             #{info.process_count}
      Limit:               #{info.process_limit}

    Ports:
      Current:             #{info.port_count}
      Limit:               #{info.port_limit}

    ETS Tables:
      Limit:               #{info.ets_limit}

    Atoms:
      Current:             #{info.atom_count}
      Limit:               #{info.atom_limit}
    """

    %{content: [%{type: "text", text: result_text}]}
  end

  defp handle_beam_schedulers(_args) do
    schedulers_online = :erlang.system_info(:schedulers_online)
    schedulers_total = :erlang.system_info(:schedulers)

    stats = :erlang.statistics(:scheduler_wall_time)
    Process.sleep(1000)
    stats2 = :erlang.statistics(:scheduler_wall_time)

    header = """
    BEAM Scheduler Information:

    Schedulers Total:  #{schedulers_total}
    Schedulers Online: #{schedulers_online}

    """

    scheduler_details =
      if stats && stats2 do
        utilizations = calculate_scheduler_utilization(stats, stats2)

        details =
          Enum.map_join(utilizations, "\n", fn {id, util} ->
            percent = Float.round(util * 100, 2)
            "  Scheduler #{id}: #{percent}%"
          end)

        avg_util =
          if utilizations != [] do
            avg =
              utilizations
              |> Enum.map(fn {_, util} -> util end)
              |> Enum.sum()
              |> Kernel./(length(utilizations))

            Float.round(avg * 100, 2)
          else
            0.0
          end

        "Scheduler Utilization (1 second sample):\n#{details}\n\nAverage Utilization: #{avg_util}%"
      else
        "Scheduler wall time statistics not available (enable with: :erlang.system_flag(:scheduler_wall_time, true))"
      end

    %{content: [%{type: "text", text: header <> scheduler_details}]}
  end

  defp handle_beam_applications(_args) do
    started = Application.started_applications()

    apps =
      Application.loaded_applications()
      |> Enum.map(fn {app, desc, version} ->
        status = if Enum.any?(started, fn {a, _, _} -> a == app end), do: "started", else: "loaded"
        %{name: app, description: desc, version: version, status: status}
      end)
      |> Enum.sort_by(& &1.name)

    result_text =
      if Enum.empty?(apps) do
        "No applications loaded"
      else
        header = "OTP Applications (#{length(apps)}):\n\n"

        apps_text =
          Enum.map_join(apps, "\n\n", fn app ->
            indicator = if app.status == "started", do: "✓", else: "○"
            "#{indicator} #{app.name} (#{app.version})\n  #{app.description}"
          end)

        header <> apps_text
      end

    %{content: [%{type: "text", text: result_text}]}
  end

  defp handle_beam_ets_tables(args) do
    limit = Map.get(args, "limit", 20)

    tables =
      :ets.all()
      |> Enum.map(fn table ->
        try do
          info = :ets.info(table)

          %{
            name: info[:name],
            size: info[:size] || 0,
            memory: info[:memory] || 0,
            type: info[:type],
            protection: info[:protection],
            owner: inspect(info[:owner])
          }
        rescue
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.memory, :desc)
      |> Enum.take(limit)

    result_text =
      if Enum.empty?(tables) do
        "No ETS tables found"
      else
        header = "ETS Tables (top #{length(tables)} by memory):\n\n"
        word_size = :erlang.system_info(:wordsize)

        tables_text =
          Enum.map_join(tables, "\n\n", fn table ->
            mem_kb = Float.round(table.memory * word_size / 1024, 2)
            "#{table.name}\n  Size: #{table.size} objects\n  Memory: #{mem_kb} KB\n  Type: #{table.type}, Protection: #{table.protection}\n  Owner: #{table.owner}"
          end)

        header <> tables_text
      end

    %{content: [%{type: "text", text: result_text}]}
  end

  # Private Helpers

  defp calculate_scheduler_utilization(stats1, stats2) do
    Enum.zip(stats1, stats2)
    |> Enum.map(fn {{id, active1, total1}, {id, active2, total2}} ->
      active_diff = active2 - active1
      total_diff = total2 - total1
      utilization = if total_diff > 0, do: active_diff / total_diff, else: 0.0
      {id, utilization}
    end)
  end

  defp format_function({module, function, arity}), do: "#{module}.#{function}/#{arity}"
  defp format_function(_), do: "unknown"
end
