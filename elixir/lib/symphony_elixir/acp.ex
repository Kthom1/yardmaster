defmodule SymphonyElixir.Acp do
  @moduledoc """
  Runs agent turns through an Agent Client Protocol (v1) agent over stdio.

  Keeps the `SymphonyElixir.Codex.AppServer` session contract and event shapes, so
  the orchestrator, retries and dashboard are unchanged. Tracker tools reach the
  agent through `SymphonyElixir.Acp.ToolServer`; tracker secrets are removed from
  the agent's environment. The client advertises no filesystem or terminal
  capabilities, so agents use their own tools inside the workspace.
  """

  require Logger
  alias SymphonyElixir.{Acp.ToolServer, Codex.DynamicTool, Config, PathSafety}

  @protocol_version 1
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @method_not_found -32_601

  @type session :: %{
          port: port(),
          metadata: map(),
          session_id: String.t(),
          tool_server: ToolServer.t(),
          usage: :counters.counters_ref()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts) do
    case Keyword.get(opts, :worker_host) do
      nil -> start_local_session(workspace, Keyword.get(opts, :issue))
      host -> {:error, {:acp_remote_worker_unsupported, host}}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{session_id: session_id} = session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)
    turn_id = "turn-#{System.unique_integer([:positive, :monotonic])}"
    turn_session_id = "#{session_id}-#{turn_id}"
    ids = %{session_id: turn_session_id, thread_id: session_id, turn_id: turn_id}

    :ok = ToolServer.bind_issue(session.tool_server, issue)
    Logger.info("ACP session started for #{issue_context(issue)} session_id=#{turn_session_id}")
    emit(on_message, session, :session_started, ids)

    params = %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => prompt}]}

    case request(session, "session/prompt", params, Config.settings!().codex.turn_timeout_ms, on_message) do
      {:ok, result} ->
        details = %{payload: turn_payload(session, result), details: result}
        finish_turn(result["stopReason"], result, details, ids, issue, session, on_message)

      {:error, :timeout} ->
        notify(session.port, "session/cancel", %{"sessionId" => session_id})
        turn_error(:turn_timeout, turn_session_id, issue, session, on_message)

      {:error, reason} ->
        turn_error(reason, turn_session_id, issue, session, on_message)
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(session), do: close(session)

  defp start_local_session(workspace, issue) do
    settings = Config.settings!().acp
    binding = DynamicTool.bind()

    # The tracker tool relay runs on the host's Python 3.
    with {:ok, workspace} <- validate_workspace(workspace),
         python when is_binary(python) <- System.find_executable("python3") || {:error, :python3_not_found} do
      tool_server = ToolServer.start(binding, issue)
      port = start_port(workspace, settings.command, binding.secret_environment_names)
      session = %{port: port, metadata: port_metadata(port), tool_server: tool_server, usage: :counters.new(3, [])}

      case open_session(session, workspace, python, settings) do
        {:ok, session_id} ->
          {:ok, Map.put(session, :session_id, session_id)}

        {:error, reason} ->
          close(session)
          {:error, reason}
      end
    end
  end

  defp open_session(session, workspace, python, settings) do
    timeout = settings.read_timeout_ms
    ignore = fn _message -> :ok end

    initialize = %{
      "protocolVersion" => @protocol_version,
      "clientCapabilities" => %{"fs" => %{"readTextFile" => false, "writeTextFile" => false}, "terminal" => false},
      "clientInfo" => %{"name" => "yardmaster", "version" => "1"}
    }

    new_session =
      %{"cwd" => workspace, "mcpServers" => ToolServer.mcp_servers(session.tool_server, python)}
      |> put_meta(settings.session_meta)

    with {:ok, init} <- request(session, "initialize", initialize, timeout, ignore),
         :ok <- check_protocol_version(init),
         {:ok, %{"sessionId" => session_id}} when is_binary(session_id) <-
           request(session, "session/new", new_session, timeout, ignore),
         :ok <- set_config_options(session, session_id, settings.config_options, timeout) do
      {:ok, session_id}
    else
      {:ok, other} -> {:error, {:invalid_acp_response, other}}
      error -> error
    end
  end

  defp close(%{port: port, tool_server: tool_server}) do
    stop_port(port)
    ToolServer.stop(tool_server)
  end

  defp check_protocol_version(%{"protocolVersion" => @protocol_version}), do: :ok
  defp check_protocol_version(init), do: {:error, {:unsupported_acp_protocol_version, init["protocolVersion"]}}

  defp put_meta(params, meta) when map_size(meta) == 0, do: params
  defp put_meta(params, meta), do: Map.put(params, "_meta", meta)

  defp set_config_options(session, session_id, options, timeout) do
    Enum.reduce_while(options, :ok, fn {config_id, value}, :ok ->
      set_config_option(session, session_id, config_id, value, timeout)
    end)
  end

  defp set_config_option(session, session_id, config_id, value, timeout) do
    params = %{"sessionId" => session_id, "configId" => config_id, "value" => value}

    case request(session, "session/set_config_option", params, timeout, fn _message -> :ok end) do
      {:ok, _result} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:acp_config_option_failed, config_id, reason}}}
    end
  end

  defp finish_turn("end_turn", result, details, ids, issue, session, on_message) do
    Logger.info("ACP session completed for #{issue_context(issue)} session_id=#{ids.session_id}")
    emit(on_message, session, :turn_completed, details)
    {:ok, Map.put(ids, :result, result)}
  end

  defp finish_turn("cancelled", result, details, _ids, _issue, session, on_message) do
    emit(on_message, session, :turn_cancelled, details)
    {:error, {:turn_cancelled, result}}
  end

  defp finish_turn(_stop_reason, result, details, ids, issue, session, on_message) do
    Logger.warning("ACP turn stopped for #{issue_context(issue)} session_id=#{ids.session_id} stop_reason=#{result["stopReason"]}")
    emit(on_message, session, :turn_failed, details)
    {:error, {:turn_failed, result}}
  end

  defp turn_error(reason, turn_session_id, issue, session, on_message) do
    Logger.warning("ACP session ended with error for #{issue_context(issue)} session_id=#{turn_session_id}: #{inspect(reason)}")
    emit(on_message, session, :turn_ended_with_error, %{session_id: turn_session_id, reason: reason})
    {:error, reason}
  end

  # ACP reports usage per turn; the orchestrator expects cumulative totals per worker.
  defp turn_payload(%{usage: usage}, result) do
    turn_usage = Map.get(result, "usage") || %{}

    for {index, key} <- [{1, "inputTokens"}, {2, "outputTokens"}, {3, "totalTokens"}],
        is_integer(turn_usage[key]) and turn_usage[key] >= 0 do
      :counters.add(usage, index, turn_usage[key])
    end

    total = %{
      "input_tokens" => :counters.get(usage, 1),
      "output_tokens" => :counters.get(usage, 2),
      "total_tokens" => :counters.get(usage, 3)
    }

    %{"method" => "session/prompt", "result" => result, "tokenUsage" => %{"total" => total}}
  end

  defp request(session, method, params, timeout, on_message) do
    id = System.unique_integer([:positive, :monotonic])
    send_message(session.port, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    await(session, id, timeout, on_message, "")
  end

  defp await(%{port: port} = session, id, timeout, on_message, pending) do
    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        await(session, id, timeout, on_message, pending <> chunk)

      {^port, {:data, {:eol, chunk}}} ->
        case handle_line(session, id, pending <> chunk, on_message) do
          :continue -> await(session, id, timeout, on_message, "")
          {:response, response} -> response
        end

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp handle_line(session, id, line, on_message) do
    case Jason.decode(line) do
      {:ok, %{"id" => ^id, "result" => result} = message} when not is_map_key(message, "method") ->
        {:response, {:ok, result}}

      {:ok, %{"id" => ^id, "error" => error} = message} when not is_map_key(message, "method") ->
        {:response, {:error, {:response_error, error}}}

      {:ok, %{"method" => "session/request_permission", "id" => request_id} = message} ->
        answer_permission(session, request_id, message, line, on_message)

      {:ok, %{"method" => method, "id" => request_id} = message} ->
        # Filesystem, terminal and elicitation requests are not advertised.
        respond(session.port, request_id, %{"error" => %{"code" => @method_not_found, "message" => "Method not found: #{method}"}})
        emit(on_message, session, :unsupported_tool_call, %{payload: message, raw: line})
        :continue

      {:ok, %{"method" => _method} = message} ->
        emit(on_message, session, :notification, %{payload: message, raw: line})
        :continue

      {:ok, _other_response} ->
        :continue

      {:error, _reason} ->
        log_stream_line(line)
        :continue
    end
  end

  # Unattended runs cannot answer prompts: allow once, never persist a rule.
  defp answer_permission(session, request_id, message, line, on_message) do
    options = get_in(message, ["params", "options"]) || []

    case Enum.find(options, &(&1["kind"] == "allow_once")) do
      %{"optionId" => option_id} ->
        respond(session.port, request_id, %{"result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}})
        emit(on_message, session, :approval_auto_approved, %{payload: message, raw: line, decision: option_id})

      _ ->
        respond(session.port, request_id, %{"result" => %{"outcome" => %{"outcome" => "cancelled"}}})
        emit(on_message, session, :approval_required, %{payload: message, raw: line})
    end

    :continue
  end

  defp validate_workspace(workspace) do
    with {:ok, canonical} <- PathSafety.canonicalize(workspace),
         {:ok, root} <- PathSafety.canonicalize(Config.local_workspace_root()) do
      if canonical != root and String.starts_with?(canonical, root <> "/") do
        {:ok, canonical}
      else
        {:error, {:invalid_workspace_cwd, canonical, root}}
      end
    end
  end

  defp start_port(workspace, command, secret_environment_names) do
    names = Enum.filter(secret_environment_names, &String.match?(&1, ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/))
    launch = Enum.map_join(names, "", &"unset #{&1} && ") <> "exec #{command}"

    # The agent's stderr goes to Symphony's stderr, never into the protocol stream.
    Port.open({:spawn_executable, String.to_charlist(System.find_executable("bash"))}, [
      :binary,
      :exit_status,
      args: [~c"-lc", String.to_charlist(launch)],
      cd: String.to_charlist(workspace),
      env: Enum.map(names, &{String.to_charlist(&1), false}),
      line: @port_line_bytes
    ])
  end

  defp port_metadata(port) do
    {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
    %{codex_app_server_pid: to_string(os_pid)}
  end

  # The port may already be closed after the agent exited.
  defp stop_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp send_message(port, message), do: Port.command(port, Jason.encode!(message) <> "\n")
  defp respond(port, id, body), do: send_message(port, Map.merge(%{"jsonrpc" => "2.0", "id" => id}, body))
  defp notify(port, method, params), do: send_message(port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})

  defp emit(on_message, session, event, details) do
    session.metadata
    |> Map.merge(details)
    |> Map.put(:event, event)
    |> Map.put(:timestamp, DateTime.utc_now())
    |> on_message.()
  end

  # Stdout carries only the protocol; anything else is unexpected.
  defp log_stream_line(line) do
    text = line |> String.trim() |> String.slice(0, @max_stream_log_bytes)
    if text != "", do: Logger.warning("ACP agent wrote non-protocol output: #{text}")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}), do: "issue_id=#{issue_id} issue_identifier=#{identifier}"
end
