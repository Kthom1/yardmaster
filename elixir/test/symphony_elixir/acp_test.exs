defmodule SymphonyElixir.AcpTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Acp, AgentSession}
  alias SymphonyElixir.Config.Schema

  @project "11111111-1111-4111-8111-111111111111"

  defmodule RaisingTracker do
    def execute_agent_tool(_tool, _arguments, _opts), do: raise("tracker failure")
  end

  defmodule EchoTracker do
    def execute_agent_tool(_tool, _arguments, opts), do: %{"success" => true, "output" => Keyword.fetch!(opts, :issue).identifier}
  end

  # FAKE_ACP_MODE selects failure behaviour; FAKE_ACP_STOP selects the prompt stop reason.
  @fake_agent ~S"""
  import json, os, subprocess, sys

  trace = open(os.environ["FAKE_ACP_TRACE"], "a")
  mode = os.environ.get("FAKE_ACP_MODE", "")
  stop = os.environ.get("FAKE_ACP_STOP", "end_turn")
  prompt_id = None

  def log(kind, value):
      trace.write(json.dumps({"kind": kind, "value": value}) + "\n")
      trace.flush()

  def send(message):
      sys.stdout.write(json.dumps(dict(jsonrpc="2.0", **message)) + "\n")
      sys.stdout.flush()

  def call_tools(server):
      env = dict(os.environ, **{item["name"]: item["value"] for item in server["env"]})
      child = subprocess.Popen([server["command"], *server["args"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
      def rpc(id, method, params):
          child.stdin.write(json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params}) + "\n")
          child.stdin.flush()
          return json.loads(child.stdout.readline())
      rpc(1, "initialize", {"protocolVersion": "2025-06-18"})
      child.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n\n")
      log("ping", rpc(2, "ping", {}))
      log("unknown", rpc(3, "resources/list", {}))
      log("tools", rpc(4, "tools/list", {})["result"])
      log("call", rpc(5, "tools/call", {"name": "plane", "arguments": {"action": "read", "issue_id": "not-a-uuid"}})["result"])
      child.stdin.close()
      child.wait()

  for line in sys.stdin:
      message = json.loads(line)
      log("in", message)
      method = message.get("method")
      if method == "initialize":
          send({"id": message["id"], "result": {"protocolVersion": int(os.environ.get("FAKE_ACP_VERSION", "1"))}})
      elif method == "session/new":
          log("secret", os.environ.get("TRACKER_TEST_TOKEN"))
          for server in message["params"]["mcpServers"]:
              call_tools(server)
          send({"id": message["id"], "result": {} if mode == "no-session" else {"sessionId": "sess-1"}})
      elif method == "session/set_config_option":
          if mode == "config-error":
              send({"id": message["id"], "error": {"code": -32602, "message": "unknown option"}})
          else:
              send({"id": message["id"], "result": {"configOptions": []}})
      elif method == "session/prompt":
          if mode == "exit":
              sys.exit(3)
          prompt_id = message["id"]
          sys.stdout.write("\nnot a protocol message\n")
          send({"id": 999, "result": {}})
          send({"method": "session/update", "params": {"sessionId": "sess-1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "x" * 1_100_000}}}})
          if stop != "silent":
              options = [{"optionId": "no", "kind": "reject_once"}]
              if mode != "deny":
                  options += [{"optionId": "always", "kind": "allow_always"}]
              if mode not in ("deny", "always-only"):
                  options += [{"optionId": "once", "kind": "allow_once"}]
              send({"id": 100, "method": "session/request_permission", "params": {"sessionId": "sess-1", "options": options}})
      elif message.get("id") == 100:
          send({"id": 101, "method": "fs/read_text_file", "params": {"sessionId": "sess-1", "path": "/etc/hostname"}})
      elif message.get("id") == 101:
          result = {"usage": {"inputTokens": 10, "outputTokens": 5, "totalTokens": 15}}
          if stop != "none":
              result["stopReason"] = stop
          # Split the response around stderr output; stderr must not corrupt it.
          line = json.dumps({"jsonrpc": "2.0", "id": prompt_id, "result": result}) + "\n"
          sys.stdout.write(line[:20])
          sys.stdout.flush()
          print("adapter diagnostic mid-response", file=sys.stderr, flush=True)
          sys.stdout.write(line[20:])
          sys.stdout.flush()
  """

  setup do
    runtime_running? = is_pid(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor))

    if runtime_running? do
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.AgentRuntimeSupervisor)
    end

    root = Path.join(System.tmp_dir!(), "symphony-acp-test-#{System.unique_integer([:positive])}")
    workspace = Path.join([root, "workspaces", "SY-1"])
    File.mkdir_p!(workspace)
    agent = Path.join(root, "fake_agent.py")
    File.write!(agent, @fake_agent)
    trace = Path.join(root, "trace.jsonl")

    names = ~w(TRACKER_TEST_TOKEN FAKE_ACP_TRACE FAKE_ACP_MODE FAKE_ACP_STOP FAKE_ACP_VERSION)
    previous = for name <- names, into: %{}, do: {name, System.get_env(name)}
    System.put_env("TRACKER_TEST_TOKEN", "test-secret")
    System.put_env("FAKE_ACP_TRACE", trace)

    on_exit(fn ->
      Enum.each(previous, fn {name, value} -> restore_env(name, value) end)
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      File.rm_rf(root)

      if runtime_running? do
        {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.AgentRuntimeSupervisor)
      end
    end)

    %{root: root, workspace: workspace, agent: agent, trace: trace}
  end

  test "runs turns through an ACP agent with relayed tracker tools and no tracker secrets", ctx do
    write_workflow!(ctx, """
    acp:
      command: python3 #{ctx.agent}
      session_meta:
        claudeCode:
          options:
            settingSources: [project]
      config_options:
        mode: bypassPermissions
    """)

    assert AgentSession.backend() == Acp
    assert {:ok, session} = AgentSession.start_session(ctx.workspace, issue: issue())
    tool_dir = session.session.tool_server.dir

    on_message = fn message -> send(self(), {:event, message}) end
    assert {:ok, %{session_id: "sess-1-" <> _}} = AgentSession.run_turn(session, "first", issue(), on_message: on_message)
    assert {:ok, _turn} = AgentSession.run_turn(session, "second", issue(), on_message: on_message)
    :ok = AgentSession.stop_session(session)
    refute File.exists?(tool_dir)

    events = collect_events()
    assert Enum.count(events, &(&1.event == :session_started)) == 2
    assert Enum.any?(events, &(&1.event == :notification and byte_size(&1.raw) > 1_048_576))
    assert Enum.any?(events, &(&1.event == :approval_auto_approved and &1.decision == "once"))
    assert Enum.any?(events, &(&1.event == :unsupported_tool_call))

    assert [_first, %{payload: %{"tokenUsage" => %{"total" => total}}}] = Enum.filter(events, &(&1.event == :turn_completed))
    assert total == %{"input_tokens" => 20, "output_tokens" => 10, "total_tokens" => 30}

    trace = read_trace(ctx.trace)
    [initialize] = received(trace, "initialize")
    assert initialize["params"]["clientCapabilities"] == %{"fs" => %{"readTextFile" => false, "writeTextFile" => false}, "terminal" => false}

    [new_session] = received(trace, "session/new")
    assert new_session["params"]["cwd"] == resolve(ctx.workspace)
    assert new_session["params"]["_meta"] == %{"claudeCode" => %{"options" => %{"settingSources" => ["project"]}}}

    assert [%{"params" => %{"sessionId" => "sess-1", "configId" => "mode", "value" => "bypassPermissions"}}] =
             received(trace, "session/set_config_option")

    assert values(trace, "secret") == [nil]
    assert [%{"result" => %{}}] = values(trace, "ping")
    assert [%{"error" => %{"code" => -32_601}}] = values(trace, "unknown")
    assert [%{"tools" => [%{"name" => "plane", "inputSchema" => %{}}]}] = values(trace, "tools")
    assert [%{"isError" => true, "content" => [%{"text" => text}]}] = values(trace, "call")
    assert text =~ "invalid_plane_issue_id"

    assert %{"result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "once"}}} = response(trace, 100)
    assert %{"error" => %{"code" => -32_601}} = response(trace, 101)
  end

  test "turns fail on unsuccessful stops, agent exits and silence; unanswerable permissions are cancelled", ctx do
    write_workflow!(ctx, "acp:\n  command: python3 #{ctx.agent}\n", "codex:\n  turn_timeout_ms: 300\n")

    for {stop, expected} <- [{"refusal", :turn_failed}, {"none", :turn_failed}, {"cancelled", :turn_cancelled}] do
      System.put_env("FAKE_ACP_STOP", stop)
      assert {:ok, session} = Acp.start_session(ctx.workspace, issue: issue())
      assert {:error, {^expected, _result}} = Acp.run_turn(session, "prompt", issue())
      Acp.stop_session(session)
    end

    System.put_env("FAKE_ACP_STOP", "end_turn")

    for mode <- ["deny", "always-only"] do
      System.put_env("FAKE_ACP_MODE", mode)
      assert {:ok, session} = Acp.start_session(ctx.workspace, issue: issue())
      on_message = fn message -> send(self(), {:event, message}) end
      assert {:ok, _turn} = Acp.run_turn(session, "prompt", issue(), on_message: on_message)
      assert Enum.any?(collect_events(), &(&1.event == :approval_required))
      assert %{"result" => %{"outcome" => %{"outcome" => "cancelled"}}} = response(read_trace(ctx.trace), 100)
      Acp.stop_session(session)
    end

    System.put_env("FAKE_ACP_MODE", "exit")
    assert {:ok, session} = Acp.start_session(ctx.workspace, issue: issue())
    assert {:error, {:port_exit, 3}} = Acp.run_turn(session, "prompt", issue())
    assert :ok = Acp.stop_session(session)

    System.put_env("FAKE_ACP_MODE", "")
    System.put_env("FAKE_ACP_STOP", "silent")
    assert {:ok, session} = Acp.start_session(ctx.workspace, issue: issue())
    assert {:error, :turn_timeout} = Acp.run_turn(session, "prompt", issue())
    assert eventually(fn -> received(read_trace(ctx.trace), "session/cancel") != [] end)
    Acp.stop_session(session)
  end

  test "sessions fail closed on protocol, session, config, workspace and remote-host mismatches", ctx do
    write_workflow!(ctx, "acp:\n  command: python3 #{ctx.agent}\n  config_options:\n    mode: auto\n")

    System.put_env("FAKE_ACP_VERSION", "2")
    assert {:error, {:unsupported_acp_protocol_version, 2}} = Acp.start_session(ctx.workspace, issue: issue())
    System.put_env("FAKE_ACP_VERSION", "1")

    System.put_env("FAKE_ACP_MODE", "no-session")
    assert {:error, {:invalid_acp_response, %{}}} = Acp.start_session(ctx.workspace, issue: issue())

    System.put_env("FAKE_ACP_MODE", "config-error")

    assert {:error, {:acp_config_option_failed, "mode", {:response_error, %{"code" => -32_602}}}} =
             Acp.start_session(ctx.workspace, issue: issue())

    path = System.get_env("PATH")
    System.put_env("PATH", ctx.root)
    assert {:error, :python3_not_found} = Acp.start_session(ctx.workspace, issue: issue())
    System.put_env("PATH", path)

    assert {:error, {:invalid_workspace_cwd, _path, _root}} = Acp.start_session(Path.join(ctx.root, "workspaces"), issue: issue())
    assert {:error, {:acp_remote_worker_unsupported, "worker"}} = Acp.start_session(ctx.workspace, worker_host: "worker")
    assert Path.wildcard(Path.join(System.tmp_dir!(), "symphony-acp-tools-*")) == []
  end

  test "tool sockets serve only connections that present the session token" do
    server = Acp.ToolServer.start(%{tool_specs: [%{"name" => "plane", "description" => "d", "inputSchema" => %{}}]}, issue())

    for sent <- ["wrong-token\n" <> rpc("tools/list"), "\n" <> rpc("tools/list"), String.duplicate("x", 100)] do
      {:ok, conn} = :gen_tcp.connect({:local, server.socket}, 0, [:binary, active: false])
      :ok = :gen_tcp.send(conn, sent)
      assert {:error, :closed} = :gen_tcp.recv(conn, 0, 1_000)
    end

    {:ok, conn} = :gen_tcp.connect({:local, server.socket}, 0, [:binary, active: false])
    :ok = :gen_tcp.send(conn, "partial")
    :ok = :gen_tcp.close(conn)

    conn = authenticated(server, String.slice(server.token, 0, 5))
    assert %{"result" => %{"tools" => [%{"name" => "plane"}]}} = call(conn, "tools/list")

    Acp.ToolServer.stop(server)
    assert {:error, :closed} = :gen_tcp.recv(conn, 0, 1_000)
  end

  test "a failing tracker tool returns an error and leaves the connection usable" do
    binding = %{adapter: __MODULE__.RaisingTracker, tracker_settings: %{}, tool_specs: []}
    server = Acp.ToolServer.start(binding, issue())
    conn = authenticated(server, "")

    log = capture_log(fn -> assert %{"error" => %{"code" => -32_603}} = call(conn, "tools/call", %{"name" => "plane"}) end)
    assert log =~ "ACP tool request failed"
    assert %{"result" => %{}} = call(conn, "ping")
    Acp.ToolServer.stop(server)
  end

  test "tool calls use the work item bound for the current turn" do
    server = Acp.ToolServer.start(%{adapter: __MODULE__.EchoTracker, tracker_settings: %{}, tool_specs: []}, issue())
    conn = authenticated(server, "")
    assert %{"result" => %{"content" => [%{"text" => "SY-1"}]}} = call(conn, "tools/call", %{"name" => "plane"})

    :ok = Acp.ToolServer.bind_issue(server, %{issue() | identifier: "WEB-1"})
    assert %{"result" => %{"content" => [%{"text" => "WEB-1"}]}} = call(conn, "tools/call", %{"name" => "plane"})
    Acp.ToolServer.stop(server)
  end

  test "tool files and connections are removed when a worker is killed without stopping its session" do
    test_pid = self()

    worker =
      spawn(fn ->
        send(test_pid, {:server, Acp.ToolServer.start(%{tool_specs: []}, issue())})
        Process.sleep(:infinity)
      end)

    assert_receive {:server, server}
    conn = authenticated(server, "")
    assert %{"result" => %{}} = call(conn, "ping")
    assert File.exists?(server.dir)
    Process.exit(worker, :kill)
    assert eventually(fn -> not File.exists?(server.dir) end)
    assert {:error, :closed} = :gen_tcp.recv(conn, 0, 1_000)
  end

  test "Codex stays the default backend and a blank ACP command is invalid", ctx do
    write_workflow!(ctx, "")
    assert AgentSession.backend() == AppServer
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"acp" => %{"command" => " "}})
    assert message =~ "acp.command"

    blank = %{"command" => "agent", "session_meta" => nil, "config_options" => nil, "read_timeout_ms" => nil}
    assert {:ok, %{acp: %{session_meta: %{}, config_options: %{}, read_timeout_ms: 60_000}}} = Schema.parse(%{"acp" => blank})

    wrong = %{"command" => "agent", "session_meta" => "", "config_options" => [], "read_timeout_ms" => "soon"}
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"acp" => wrong})
    assert message =~ "acp.session_meta" and message =~ "acp.config_options" and message =~ "acp.read_timeout_ms"
  end

  defp write_workflow!(ctx, acp, codex \\ "") do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: plane
      provider:
        endpoint: http://localhost:8090
        workspace: demo
        project_id: #{@project}
        project_identifier: SY
        api_key: $TRACKER_TEST_TOKEN
      required_labels: [agent]
      active_states: [Todo, In Progress]
      terminal_states: [Done, Cancelled]
    polling:
      interval_ms: 3600000
    workspace:
      root: #{Path.join(ctx.root, "workspaces")}
    #{codex}#{acp}---
    Test
    """)

    WorkflowStore.force_reload()
  end

  defp rpc(method, params \\ %{}), do: Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}) <> "\n"

  defp authenticated(server, first_chunk) do
    {:ok, conn} = :gen_tcp.connect({:local, server.socket}, 0, [:binary, active: false])
    :ok = :gen_tcp.send(conn, first_chunk)
    :ok = :gen_tcp.send(conn, String.replace_prefix(server.token, first_chunk, "") <> "\n")
    conn
  end

  defp call(conn, method, params \\ %{}) do
    :ok = :gen_tcp.send(conn, rpc(method, params))
    {:ok, reply} = :gen_tcp.recv(conn, 0, 1_000)
    Jason.decode!(reply)
  end

  defp issue, do: %Issue{id: "22222222-2222-4222-8222-222222222222", identifier: "SY-1", title: "Test", state: "In Progress"}

  defp collect_events(events \\ []) do
    receive do
      {:event, event} -> collect_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp read_trace(path), do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  defp received(trace, method), do: for(%{"kind" => "in", "value" => %{"method" => ^method} = message} <- trace, do: message)
  defp values(trace, kind), do: for(%{"kind" => ^kind, "value" => value} <- trace, do: value)

  defp response(trace, id) do
    trace
    |> Enum.filter(&(&1["kind"] == "in" and &1["value"]["id"] == id and not Map.has_key?(&1["value"], "method")))
    |> List.last()
    |> Map.fetch!("value")
  end

  defp resolve(path) do
    {:ok, canonical} = SymphonyElixir.PathSafety.canonicalize(path)
    canonical
  end

  defp eventually(check, attempts \\ 50) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end
end
