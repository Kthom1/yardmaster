defmodule SymphonyElixir.Acp.ToolServer do
  @moduledoc """
  Serves the bound tracker tools to one ACP agent session as an MCP server.

  ACP agents must support stdio MCP servers, so the agent launches a small relay
  that connects back over a Unix socket in a private directory. Tool calls run
  here, in the Symphony process, with the tracker binding captured at session
  start; the agent never receives tracker credentials. Each connection must
  first present the session's random token, which only that session's relay
  receives, so an agent cannot use another session's socket.
  """

  require Logger
  alias SymphonyElixir.Codex.DynamicTool

  @type t :: %{acceptor: pid(), issue: pid(), dir: Path.t(), socket: Path.t(), relay: Path.t(), token: String.t()}

  @method_not_found -32_601

  @relay """
  import os, socket, sys, threading
  conn = socket.socket(socket.AF_UNIX)
  conn.connect(sys.argv[1])
  conn.sendall(os.environ["TOOL_RELAY_TOKEN"].encode() + b"\\n")
  def upstream():
      for chunk in iter(lambda: sys.stdin.buffer.read1(65536), b""):
          conn.sendall(chunk)
      conn.shutdown(socket.SHUT_WR)
  threading.Thread(target=upstream, daemon=True).start()
  for chunk in iter(lambda: conn.recv(65536), b""):
      sys.stdout.buffer.write(chunk)
      sys.stdout.buffer.flush()
  """

  @spec start(map(), map()) :: t()
  def start(binding, issue) do
    # A random name never reuses a directory left behind by an earlier runtime.
    dir = Path.join(System.tmp_dir!(), "symphony-acp-tools-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false))
    socket = Path.join(dir, "tools.sock")
    relay = Path.join(dir, "relay.py")
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    File.write!(relay, @relay)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ifaddr: {:local, socket}])
    # Tool calls use the work item of the current turn, as the Codex backend does.
    {:ok, current_issue} = Agent.start(fn -> issue end)
    # Connection handlers are linked to the acceptor, so ending it closes every connection.
    acceptor = spawn(fn -> accept_loop(listener, token, binding, current_issue) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)
    server = %{acceptor: acceptor, issue: current_issue, dir: dir, socket: socket, relay: relay, token: token}
    stop_when_down(self(), server)
    server
  end

  @doc "Binds tool calls to the work item of the turn that is starting."
  @spec bind_issue(t(), map()) :: :ok
  def bind_issue(%{issue: current_issue}, issue), do: Agent.update(current_issue, fn _previous -> issue end)

  @spec stop(t()) :: :ok
  def stop(%{acceptor: acceptor, issue: current_issue, dir: dir}) do
    Process.exit(acceptor, :shutdown)
    Process.exit(current_issue, :shutdown)
    File.rm_rf(dir)
    :ok
  end

  @spec mcp_servers(t(), Path.t()) :: [map()]
  def mcp_servers(%{socket: socket, relay: relay, token: token}, python) do
    [%{"name" => "yardmaster", "command" => python, "args" => [relay, socket], "env" => [%{"name" => "TOOL_RELAY_TOKEN", "value" => token}]}]
  end

  # Workers stopped by the orchestrator exit without running stop/1.
  defp stop_when_down(owner, server) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> stop(server)
      end
    end)
  end

  defp accept_loop(listener, token, binding, current_issue) do
    {:ok, conn} = :gen_tcp.accept(listener)

    handler =
      spawn_link(fn ->
        receive do
          :go -> authenticate(conn, token, binding, current_issue, "")
        end
      end)

    :ok = :gen_tcp.controlling_process(conn, handler)
    send(handler, :go)
    accept_loop(listener, token, binding, current_issue)
  end

  defp authenticate(conn, token, binding, current_issue, buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [presented, rest] ->
        if byte_size(presented) == byte_size(token) and :crypto.hash_equals(presented, token) do
          serve_buffer(conn, binding, current_issue, rest)
        else
          :gen_tcp.close(conn)
        end

      [partial] when byte_size(partial) <= 64 ->
        case :gen_tcp.recv(conn, 0) do
          {:ok, data} -> authenticate(conn, token, binding, current_issue, partial <> data)
          {:error, _closed} -> :gen_tcp.close(conn)
        end

      _oversized ->
        :gen_tcp.close(conn)
    end
  end

  defp serve_buffer(conn, binding, current_issue, buffer) do
    [rest | lines] = buffer |> String.split("\n") |> Enum.reverse()
    lines |> Enum.reverse() |> Enum.each(&handle_line(conn, &1, binding, current_issue))
    serve(conn, binding, current_issue, rest)
  end

  defp serve(conn, binding, current_issue, buffer) do
    case :gen_tcp.recv(conn, 0) do
      {:ok, data} ->
        serve_buffer(conn, binding, current_issue, buffer <> data)

      {:error, _closed} ->
        :gen_tcp.close(conn)
    end
  end

  defp handle_line(conn, line, binding, current_issue) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "method" => method} = message} ->
        reply =
          try do
            handle_request(method, Map.get(message, "params") || %{}, binding, current_issue)
          rescue
            error ->
              Logger.warning("ACP tool request failed method=#{method}: #{Exception.message(error)}")
              %{"error" => %{"code" => -32_603, "message" => "Tool request failed"}}
          end

        :gen_tcp.send(conn, Jason.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => id}, reply)) <> "\n")

      _notification_or_invalid ->
        :ok
    end
  end

  defp handle_request("initialize", params, _binding, _current_issue) do
    %{
      "result" => %{
        "protocolVersion" => Map.get(params, "protocolVersion", "2025-06-18"),
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "yardmaster", "version" => "1"}
      }
    }
  end

  defp handle_request("ping", _params, _binding, _current_issue), do: %{"result" => %{}}

  defp handle_request("tools/list", _params, binding, _current_issue) do
    tools = Enum.map(binding.tool_specs, &Map.take(&1, ["name", "description", "inputSchema"]))
    %{"result" => %{"tools" => tools}}
  end

  defp handle_request("tools/call", %{"name" => name} = params, binding, current_issue) do
    issue = Agent.get(current_issue, & &1)
    result = DynamicTool.execute(name, Map.get(params, "arguments") || %{}, binding, issue: issue)
    text = result["output"] || Jason.encode!(result)
    %{"result" => %{"content" => [%{"type" => "text", "text" => text}], "isError" => result["success"] != true}}
  end

  defp handle_request(method, _params, _binding, _current_issue) do
    %{"error" => %{"code" => @method_not_found, "message" => "Method not found: #{method}"}}
  end
end
