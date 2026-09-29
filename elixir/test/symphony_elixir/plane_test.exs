defmodule SymphonyElixir.PlaneTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Plane
  alias SymphonyElixir.Tracker.Issue

  @project "11111111-1111-4111-8111-111111111111"
  @issue "22222222-2222-4222-8222-222222222222"
  @other_project "33333333-3333-4333-8333-333333333333"
  @other_issue "44444444-4444-4444-8444-444444444444"

  setup {Req.Test, :verify_on_exit!}

  setup do
    # Keep the background poller from consuming process-owned HTTP mocks.
    runtime_running? = is_pid(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor))

    if runtime_running? do
      :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.AgentRuntimeSupervisor)
    end

    previous = System.get_env("TRACKER_TEST_TOKEN")
    System.put_env("TRACKER_TEST_TOKEN", "test-secret")
    Application.put_env(:symphony_elixir, :plane_req_options, plug: {Req.Test, __MODULE__})

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
      active_states: [Todo, In Progress]
      terminal_states: [Done, Cancelled]
      required_labels: [agent]
    polling:
      interval_ms: 3600000
    ---
    Test
    """)

    WorkflowStore.force_reload()

    on_exit(fn ->
      restore_env("TRACKER_TEST_TOKEN", previous)
      Application.delete_env(:symphony_elixir, :plane_req_options)
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      if runtime_running? do
        {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.AgentRuntimeSupervisor)
      end
    end)

    %{tracker: Config.settings!().tracker}
  end

  test "normalizes Plane identity, state and labels; rejects cross-project and malformed rows", %{tracker: t} do
    assert {:ok, issue} = Plane.normalize_issue(raw(), t)
    assert issue.identifier == "SY-1"
    assert issue.url == "http://localhost:8090/demo/browse/SY-1/"
    assert issue.state == "Todo"
    assert issue.labels == ["agent"]
    assert issue.dispatchable
    assert {:ok, archived} = Plane.normalize_issue(Map.put(raw(), "archived_at", "2026-09-06"), t)
    refute archived.dispatchable
    assert {:error, :invalid_plane_issue} = Plane.normalize_issue(Map.put(raw(), "project", @issue), t)
    assert {:error, :invalid_plane_issue} = Plane.normalize_issue(Map.put(raw(), "state", "unexpanded"), t)
    assert {:error, :invalid_plane_issue} = Plane.normalize_issue(Map.put(raw(), "labels", [@issue]), t)
  end

  test "polling follows cursors and selects only requested states" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{@project}/work-items/"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-secret"]
      Req.Test.json(conn, %{"results" => [raw()], "next_page_results" => true, "next_cursor" => "100:1:0"})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["cursor"] == "100:1:0"
      Req.Test.json(conn, %{"results" => [put_in(raw(), ["state", "name"], "Backlog")], "next_page_results" => false})
    end)

    expect_relations()
    assert {:ok, [issue]} = Plane.fetch_issues_by_states([" todo "])
    assert issue.id == @issue
  end

  test "Todo waits for active Plane blockers while terminal blockers dispatch" do
    for {blocker_state, dispatchable?} <- [{"In Progress", false}, {"Done", true}] do
      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, [raw()])
      end)

      expect_relations(@issue, @project, [blocker_relation(@project)])
      blocker = raw() |> Map.merge(%{"id" => @other_issue, "sequence_id" => 2}) |> put_in(["state", "name"], blocker_state)
      expect_project_issue(@other_issue, @project, blocker)

      assert {:ok, [issue]} = Plane.fetch_issues_by_states(["Todo"])
      assert issue.blocked_by == [%{id: @other_issue, identifier: "SY-2", state: blocker_state}]
      assert issue.dispatchable == dispatchable?
    end
  end

  test "In Progress is an explicit dependency override" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, [put_in(raw(), ["state", "name"], "In Progress")])
    end)

    assert {:ok, [issue]} = Plane.fetch_issues_by_states(["In Progress"])
    assert issue.blocked_by == []
    assert issue.dispatchable
  end

  test "unapproved Todo tasks do not perform dependency lookups" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, [Map.put(raw(), "labels", [])])
    end)

    assert {:ok, [issue]} = Plane.fetch_issues_by_states(["Todo"])
    refute Issue.routable?(issue, ["agent"])
  end

  test "dispatch refresh sees new blockers and fails closed when their project is not configured" do
    expect_issue()
    expect_relations(@issue, @project, [blocker_relation(@other_project)])

    assert {:ok, [issue]} = Plane.fetch_issues_by_ids([@issue])
    assert issue.blocked_by == [%{id: @other_issue, identifier: nil, state: nil}]
    refute issue.dispatchable
  end

  test "dependency lookup failures remain errors on lifecycle refresh" do
    expect_issue()
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

    assert Plane.fetch_issues_by_ids([@issue]) == {:error, {:plane_http, 503}}
  end

  test "malformed or unavailable Plane dependency data holds only the affected Todo" do
    override =
      raw()
      |> Map.merge(%{"id" => @other_issue, "sequence_id" => 2})
      |> put_in(["state", "name"], "In Progress")

    for response <- [%{}, %{"blocked_by" => [%{"id" => "invalid"}]}] do
      Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, [raw(), override]) end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert String.ends_with?(conn.request_path, "/work-items/#{@issue}/relations/")
        Req.Test.json(conn, response)
      end)

      assert {:ok, issues} = Plane.fetch_issues_by_states(["Todo", "In Progress"])
      refute Enum.find(issues, &(&1.id == @issue)).dispatchable
      assert Enum.find(issues, &(&1.id == @other_issue)).dispatchable
    end

    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, [raw(), override]) end)
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
    assert {:ok, issues} = Plane.fetch_issues_by_states(["Todo", "In Progress"])
    refute Enum.find(issues, &(&1.id == @issue)).dispatchable
    assert Enum.find(issues, &(&1.id == @other_issue)).dispatchable

    for blocker_response <- [raw(), :unavailable] do
      Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, [raw(), override]) end)
      expect_relations(@issue, @project, [blocker_relation(@project)])

      Req.Test.expect(__MODULE__, fn conn ->
        case blocker_response do
          :unavailable -> Plug.Conn.send_resp(conn, 503, "")
          row -> Req.Test.json(conn, row)
        end
      end)

      assert {:ok, issues} = Plane.fetch_issues_by_states(["Todo", "In Progress"])
      refute Enum.find(issues, &(&1.id == @issue)).dispatchable
      assert Enum.find(issues, &(&1.id == @other_issue)).dispatchable
    end
  end

  test "repeated cursors fail rather than looping" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"results" => [], "next_page_results" => true, "next_cursor" => "same"})
    end)

    assert {:error, :plane_repeated_cursor} = Plane.fetch_issues_by_states(["Todo"])
  end

  test "refresh observes cancellation and omits deleted tasks" do
    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, put_in(raw(), ["state", "name"], "Cancelled"))
    end)

    assert {:ok, [%{state: "Cancelled"}]} = Plane.fetch_issues_by_ids([@issue])
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
    assert {:ok, []} = Plane.fetch_issues_by_ids([@issue])
  end

  test "HTTP auth and transport failures never look like an empty queue" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 401, "secret response") end)
    assert {:error, {:plane_http, 401}} = Plane.fetch_issues_by_states(["Todo"])
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)
    assert {:error, {:plane_http, 429}} = Plane.fetch_issues_by_ids([@issue])
  end

  test "tool escapes comments and restricts state changes and task paths", %{tracker: t} do
    expect_issue()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert String.ends_with?(conn.request_path, "/#{@issue}/comments/")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["comment_html"] == "<p>&lt;script&gt;test&lt;/script&gt;</p>"
      Req.Test.json(conn, %{"id" => "comment"})
    end)

    assert tool(t, %{"action" => "comment", "text" => "<script>test</script>"})["success"]
    refute tool(t, %{"action" => "set_state", "state" => "Done"})["success"]
    refute tool(t, %{"action" => "read", "issue_id" => "../../outside"})["success"]

    expect_issue()

    Req.Test.expect(__MODULE__, fn conn ->
      assert String.ends_with?(conn.request_path, "/states/")
      Req.Test.json(conn, [%{"id" => @project, "name" => " human review "}])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PATCH"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"state" => @project}
      Req.Test.json(conn, %{"state" => @project})
    end)

    assert tool(t, %{"action" => "set_state", "state" => "Human Review"})["success"]
  end

  test "tokens stay host-side and config fails closed", %{tracker: t} do
    assert :ok = Plane.validate_config(t)
    assert "TRACKER_TEST_TOKEN" in Plane.secret_environment_names(t)

    assert {:error, :plane_api_key_must_be_environment_reference} =
             Plane.validate_config(put_in(t, [Access.key!(:provider), "api_key"], "literal-secret"))

    assert {:error, :invalid_plane_workspace} =
             Plane.validate_config(put_in(t, [Access.key!(:provider), "workspace"], "../other"))

    assert {:error, :missing_plane_api_key} =
             Plane.validate_config(put_in(t, [Access.key!(:provider), "api_key"], "$TRACKER_MISSING_TOKEN"))

    assert Tracker.bind_agent_tools().adapter == Plane
  end

  test "invalid configuration and empty reads fail safely", %{tracker: t} do
    assert Plane.fetch_issues_by_states([]) == {:ok, []}
    assert Plane.fetch_issues_by_ids([]) == {:ok, []}
    assert Plane.fetch_issues_by_ids(["../bad"]) == {:error, :invalid_plane_issue_id}

    for {key, value, error} <- [
          {"endpoint", 42, :invalid_plane_endpoint},
          {"endpoint", "http://user:secret@localhost", :invalid_plane_endpoint},
          {"endpoint", "http://localhost:bad", :invalid_plane_endpoint},
          {"endpoint", "http://localhost:99999", :invalid_plane_endpoint},
          {"web_url", 42, :invalid_plane_web_url},
          {"web_url", "http://user:secret@localhost", :invalid_plane_web_url},
          {"web_url", "https://plane.example.test/?token=secret", :invalid_plane_web_url},
          {"project_id", "bad", :invalid_plane_project_id},
          {"project_identifier", "../bad", :invalid_plane_project_identifier}
        ] do
      assert Plane.validate_config(put_in(t, [Access.key!(:provider), key], value)) == {:error, error}
    end

    assert :ok = Plane.validate_config(put_in(t.provider["web_url"], "https://plane.example.test/"))
    refute tool(put_in(t, [Access.key!(:provider), "api_key"], "$TRACKER_MISSING_TOKEN"), %{"action" => "read"})["success"]
    refute Plane.execute_agent_tool("other", nil, [])["success"]
  end

  test "read tool returns task and comments; missing states and transport errors are failures", %{tracker: t} do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, raw()) end)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"results" => [%{"comment_html" => "<p>Already started</p>"}], "next_page_results" => false})
    end)

    response = tool(t, %{"action" => "read"})
    assert response["success"]

    assert Jason.decode!(response["output"]) == %{
             "issue" => raw(),
             "comments" => [%{"comment_html" => "<p>Already started</p>"}]
           }

    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]

    expect_issue()
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, []) end)
    assert tool(t, %{"action" => "set_state", "state" => "Blocked"})["output"] =~ "missing_plane_workflow_state"
    expect_issue()
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
    refute tool(t, %{"action" => "set_state", "state" => "Blocked"})["success"]
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert Plane.fetch_issues_by_ids([@issue]) == {:error, :plane_transport_error}
  end

  test "read tool rejects mismatched task identity and returns provider failures", %{tracker: t} do
    expect_issue(Map.put(raw(), "id", @project))
    assert tool(t, %{"action" => "read"})["output"] =~ "invalid_plane_issue"
    expect_issue()
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
    refute tool(t, %{"action" => "read"})["success"]
  end

  test "writes require the assigned task and reject missing or different binding before HTTP", %{tracker: t} do
    for args <- [%{"action" => "comment", "text" => "test"}, %{"action" => "set_state", "state" => "In Progress"}] do
      response = Plane.execute_agent_tool("plane", Map.put(args, "issue_id", @issue), tracker_settings: t)
      refute response["success"]
      assert response["output"] =~ "plane_issue_scope_mismatch"
      assert tool(t, Map.put(args, "issue_id", @project))["output"] =~ "plane_issue_scope_mismatch"
    end
  end

  test "writes recheck stopped, deleted, draft, archived, and unlabelled tasks", %{tracker: t} do
    stopped = Enum.map(["Backlog", "Human Review", "Blocked", "Done", "Cancelled"], &put_in(raw(), ["state", "name"], &1))
    unrouted = Enum.map([{"archived_at", "2026-09-06"}, {"deleted_at", "2026-09-06"}, {"is_draft", true}, {"labels", []}], fn {k, v} -> Map.put(raw(), k, v) end)

    for row <- stopped ++ unrouted,
        args <- [%{"action" => "comment", "text" => "stale comment"}, %{"action" => "set_state", "state" => "In Progress"}] do
      expect_issue(row)
      response = tool(t, args)
      refute response["success"]
      assert response["output"] =~ "plane_issue_not_dispatchable"
    end

    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
    assert tool(t, %{"action" => "comment", "text" => "test"})["output"] =~ "plane_issue_not_found"
  end

  test "repeating an observed state transition succeeds without another PATCH", %{tracker: t} do
    for state <- ["In Progress", "Human Review", "Blocked"] do
      expect_issue(put_in(raw(), ["state", "name"], " #{String.downcase(state)} "))
      response = tool(t, %{"action" => "set_state", "state" => state})
      assert response["success"]
      assert Jason.decode!(response["output"])["unchanged"]
    end
  end

  test "malformed and ambiguous state catalogues are tool errors", %{tracker: t} do
    for {states, error} <- [
          {[%{"name" => "Blocked"}], "invalid_plane_workflow_states"},
          {[%{"id" => "invalid", "name" => "Blocked"}], "invalid_plane_workflow_states"},
          {[nil], "invalid_plane_workflow_states"},
          {[%{"id" => @project, "name" => "Blocked"}, %{"id" => @issue, "name" => " blocked "}], "ambiguous_plane_workflow_state"}
        ] do
      expect_issue()
      Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, states) end)
      response = tool(t, %{"action" => "set_state", "state" => "Blocked"})
      refute response["success"]
      assert response["output"] =~ error
    end
  end

  test "redirects are not followed and uncertain comments are not retried", %{tracker: t} do
    redirect = fn conn -> conn |> Plug.Conn.put_resp_header("location", "http://other.example.test/secret") |> Plug.Conn.send_resp(302, "") end
    Req.Test.expect(__MODULE__, redirect)
    assert Plane.fetch_issues_by_ids([@issue]) == {:error, {:plane_http, 302}}

    for failure <- [redirect, &Req.Test.transport_error(&1, :timeout), &Plug.Conn.send_resp(&1, 503, "")] do
      expect_issue()

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        failure.(conn)
      end)

      refute tool(t, %{"action" => "comment", "text" => "once only"})["success"]
    end
  end

  test "uncertain state mutation is attempted once and wrong issue responses cannot authorize writes", %{tracker: t} do
    expect_issue()
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, [%{"id" => @project, "name" => "Human Review"}]) end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PATCH"
      Req.Test.transport_error(conn, :timeout)
    end)

    assert tool(t, %{"action" => "set_state", "state" => "Human Review"})["output"] =~ "plane_transport_error"
    expect_issue(Map.put(raw(), "id", @project))
    assert tool(t, %{"action" => "comment", "text" => "test"})["output"] =~ "invalid_plane_issue"
  end

  test "app-server advertises Plane and executes bound tools without giving the child tracker tokens", %{tracker: t} do
    supervisor = Process.whereis(SymphonyElixir.Supervisor)
    supervisor_monitor = Process.monitor(supervisor)
    root = Path.dirname(Workflow.workflow_file_path())
    workspace = Path.join(root, "workspaces/SY-1")
    script = Path.join(root, "fake-app-server.py")
    trace = Path.join(root, "protocol.jsonl")
    File.mkdir_p!(workspace)
    previous = System.get_env("PLANE_API_KEY")
    System.put_env("PLANE_API_KEY", "canonical-test-secret")
    on_exit(fn -> restore_env("PLANE_API_KEY", previous) end)

    File.write!(script, """
    import json, os, sys
    with open(sys.argv[1], "w") as trace:
        trace.write(json.dumps({"secrets_present": [name for name in ["PLANE_API_KEY", "TRACKER_TEST_TOKEN"] if name in os.environ]}) + "\\n")
        for line in sys.stdin:
            message = json.loads(line)
            trace.write(json.dumps(message) + "\\n")
            trace.flush()
            method = message.get("method")
            if method == "initialize":
                print(json.dumps({"id": message["id"], "result": {}}), flush=True)
            elif method == "thread/start":
                print(json.dumps({"id": message["id"], "result": {"thread": {"id": "plane-thread"}}}), flush=True)
            elif method == "turn/start":
                print(json.dumps({"id": message["id"], "result": {"turn": {"id": "plane-turn"}}}), flush=True)
                print(json.dumps({"id": 99, "method": "item/tool/call", "params": {"tool": "plane", "arguments": {"action": "comment", "issue_id": "#{@issue}", "text": "wire check"}}}), flush=True)
            elif message.get("id") == 99:
                print(json.dumps({"method": "turn/completed", "params": {"threadId": "plane-thread", "turn": {"id": "plane-turn", "status": "completed", "items": []}}}), flush=True)
                break
    """)

    command = Enum.map_join([System.find_executable("python3"), script, trace], " ", &shell_quote/1)

    workflow =
      Workflow.workflow_file_path()
      |> File.read!()
      |> String.replace("polling:\n", "codex:\n  command: #{Jason.encode!(command)}\nworkspace:\n  root: #{Jason.encode!(Path.dirname(workspace))}\npolling:\n")

    File.write!(Workflow.workflow_file_path(), workflow)
    :ok = WorkflowStore.force_reload()
    expect_issue()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-secret"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"comment_html" => "<p>wire check</p>"}
      Req.Test.json(conn, %{"id" => "wire-comment"})
    end)

    {:ok, issue} = Plane.normalize_issue(raw(), t)
    assert {:ok, _} = AppServer.run(workspace, "Check Plane tools", issue)
    [environment | messages] = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert environment == %{"secrets_present" => []}
    thread_start = Enum.find(messages, &(&1["method"] == "thread/start"))
    assert thread_start["params"]["dynamicTools"] == Plane.agent_tool_specs()
    tool_response = Enum.find(messages, &(&1["id"] == 99))
    assert tool_response["result"]["success"]
    assert Jason.decode!(tool_response["result"]["output"]) == %{"id" => "wire-comment"}
    assert Process.alive?(supervisor)
    refute_received {:DOWN, ^supervisor_monitor, :process, ^supervisor, _reason}
    Process.demonitor(supervisor_monitor, [:flush])
  end

  test "malformed pages, rows, and timestamps cannot silently pass", %{tracker: t} do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{"results" => [], "next_page_results" => true}) end)
    assert Plane.fetch_issues_by_states(["Todo"]) == {:error, :invalid_plane_page}
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{"results" => [%{}], "next_page_results" => false}) end)
    assert Plane.fetch_issues_by_states(["Todo"]) == {:error, :invalid_plane_issue}
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{}) end)
    assert Plane.fetch_issues_by_ids([@issue]) == {:error, :invalid_plane_issue}
    row = Map.merge(raw(), %{"created_at" => "2026-09-06T00:00:00Z", "updated_at" => "invalid", "is_draft" => true})
    assert {:ok, issue} = Plane.normalize_issue(row, t)
    assert issue.created_at == ~U[2026-09-06 00:00:00Z]
    assert is_nil(issue.updated_at)
    refute issue.dispatchable
  end

  test "mapped projects share polling while retaining distinct identities and trusted repositories", %{tracker: legacy} do
    tracker = multi_tracker(legacy)
    install_tracker(tracker)
    assert :ok = Plane.validate_config(tracker)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{@project}/work-items/"
      row = Map.merge(raw(), %{"repo" => "https://untrusted.example/other", "native_ref" => %{"repo_url" => "bad"}})
      Req.Test.json(conn, [row])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{@other_project}/work-items/"
      Req.Test.json(conn, [other_raw(), put_in(other_raw(), ["state", "name"], "Backlog")])
    end)

    expect_relations(@issue, @project)
    expect_relations(@other_issue, @other_project)
    assert {:ok, [first, second]} = Plane.fetch_issues_by_states(["Todo"])
    assert {first.identifier, second.identifier} == {"SY-1", "WEB-1"}
    assert {first.id, second.id} == {@issue, @other_issue}
    assert first.native_ref == %{"project_id" => @project, "repo_url" => "https://github.com/example/first.git"}
    assert second.native_ref == %{"project_id" => @other_project, "repo_url" => "git@example.com:team/second.git"}
    assert second.url == "http://localhost:8090/demo/browse/WEB-1/"
    assert {:error, :invalid_plane_issue} = Plane.normalize_issue(Map.put(raw(), "project", @issue), tracker)
  end

  test "workflows must list Plane lifecycle states", %{tracker: t} do
    for states <- [nil, [], [""], [" "], ["Todo", "\t"], [:todo]] do
      assert {:error, :missing_plane_active_states} = Plane.validate_config(%{t | active_states: states})
      assert {:error, :missing_plane_terminal_states} = Plane.validate_config(%{t | terminal_states: states})
    end

    assert {:error, :plane_active_states_must_include_todo} = Plane.validate_config(%{t | active_states: ["Ready", "In Progress"]})
    assert :ok = Plane.validate_config(%{t | active_states: [" todo ", "In Progress"]})
  end

  test "legacy single-project tool calls use the lowercase project UUID", %{tracker: t} do
    lettered = "abcdef12-3456-4abc-8def-0123456789ab"
    tracker = put_in(t, [Access.key!(:provider), "project_id"], String.upcase(lettered))

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{lettered}/work-items/#{@issue}/"
      Req.Test.json(conn, Map.put(raw(), "project", lettered))
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{lettered}/work-items/#{@issue}/comments/"
      Req.Test.json(conn, %{"results" => [], "next_page_results" => false})
    end)

    assert tool(tracker, %{"action" => "read"})["success"]
  end

  test "configured project UUIDs match Plane's lowercase identifiers in any case", %{tracker: legacy} do
    lettered = "abcdef12-3456-4abc-8def-0123456789ab"
    [first, second] = multi_tracker(legacy).provider["projects"]
    configured = %{first | "project_id" => String.upcase(lettered)}
    tracker = put_in(multi_tracker(legacy), [Access.key!(:provider), "projects"], [configured, second])
    install_tracker(tracker)
    assert :ok = Plane.validate_config(tracker)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{lettered}/work-items/"
      Req.Test.json(conn, [Map.put(raw(), "project", lettered)])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{@other_project}/work-items/"
      Req.Test.json(conn, [])
    end)

    expect_relations(@issue, lettered)
    assert {:ok, [issue]} = Plane.fetch_issues_by_states(["Todo"])
    assert issue.native_ref["project_id"] == lettered

    variant = %{configured | "project_id" => lettered, "project_identifier" => "OTHER"}
    assert {:error, :duplicate_plane_projects} = Plane.validate_config(put_in(tracker, [Access.key!(:provider), "projects"], [configured, variant]))
  end

  test "mapped project refresh searches configured scopes and exposes moves to lifecycle reconciliation", %{tracker: legacy} do
    install_tracker(multi_tracker(legacy))

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{@project}/work-items/#{@issue}/"
      Plug.Conn.send_resp(conn, 404, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{@other_project}/work-items/#{@issue}/"
      Req.Test.json(conn, Map.put(other_raw(), "id", @issue))
    end)

    expect_relations(@issue, @other_project)
    assert {:ok, [moved]} = Plane.fetch_issues_by_ids([@issue])
    assert moved.id == @issue and moved.identifier == "WEB-1"
    assert moved.native_ref["project_id"] == @other_project

    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)
    assert {:error, {:plane_http, 403}} = Plane.fetch_issues_by_states(["Todo"])
  end

  test "mapped tools use the bound project and reject foreign tasks and missing or changed routing", %{tracker: legacy} do
    tracker = multi_tracker(legacy)
    {:ok, assigned} = Plane.normalize_issue(other_raw(), tracker)
    call = fn args, issue -> Plane.execute_agent_tool("plane", args, tracker_settings: tracker, issue: issue) end
    args = %{"action" => "comment", "issue_id" => @other_issue, "text" => "second project"}

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{@other_project}/work-items/#{@other_issue}/"
      Req.Test.json(conn, other_raw())
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{@other_project}/work-items/#{@other_issue}/comments/"
      Req.Test.json(conn, %{"id" => "comment"})
    end)

    assert call.(args, assigned)["success"]

    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, other_raw()) end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{@other_project}/states/"
      Req.Test.json(conn, [%{"id" => @other_project, "name" => "Human Review"}])
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PATCH"
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{@other_project}/work-items/#{@other_issue}/"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"state" => @other_project}
      Req.Test.json(conn, %{"id" => @other_issue})
    end)

    assert call.(%{"action" => "set_state", "issue_id" => @other_issue, "state" => "Human Review"}, assigned)["success"]

    assert call.(Map.put(args, "issue_id", @issue), assigned)["output"] =~ "plane_issue_scope_mismatch"
    assert call.(args, %Issue{id: @other_issue})["output"] =~ "plane_issue_scope_mismatch"
    assert call.(args, %{assigned | native_ref: %{"project_id" => @other_project, "repo_url" => "https://other.example/repo"}})["output"] =~ "plane_issue_scope_mismatch"
    assert call.(args, %{assigned | native_ref: %{"project_id" => @issue, "repo_url" => "https://other.example/repo"}})["output"] =~ "plane_issue_scope_mismatch"

    Req.Test.expect(__MODULE__, fn conn ->
      # A read of another task never searches outside the assigned project.
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{@other_project}/work-items/#{@issue}/"
      Plug.Conn.send_resp(conn, 404, "")
    end)

    refute call.(%{"action" => "read", "issue_id" => @issue}, assigned)["success"]
  end

  test "captured tool mappings remain stable across workflow reloads", %{tracker: legacy} do
    tracker = multi_tracker(legacy)
    install_tracker(tracker)
    {:ok, assigned} = Plane.normalize_issue(raw(), tracker)
    binding = Tracker.bind_agent_tools()
    [first, second] = tracker.provider["projects"]
    changed = put_in(tracker.provider["projects"], [Map.put(first, "repo", "https://github.com/example/replacement.git"), second])
    install_tracker(changed)
    args = %{"action" => "comment", "issue_id" => @issue, "text" => "accepted mapping"}
    assert Tracker.execute_bound_agent_tool(Tracker.bind_agent_tools(), "plane", args, issue: assigned)["output"] =~ "plane_issue_scope_mismatch"

    expect_issue()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/workspaces/demo/projects/#{@project}/work-items/#{@issue}/comments/"
      Req.Test.json(conn, %{"id" => "comment"})
    end)

    assert Tracker.execute_bound_agent_tool(binding, "plane", args, issue: assigned)["success"]
  end

  test "mapping validation rejects missing, ambiguous, duplicate and unsafe routes", %{tracker: legacy} do
    tracker = multi_tracker(legacy)
    [first, second] = tracker.provider["projects"]

    for projects <- [[], "invalid", [nil], [Map.delete(first, "repo")], [Map.put(first, "project_id", "bad")]] do
      assert {:error, :invalid_plane_projects} = Plane.validate_config(put_in(tracker.provider["projects"], projects))
    end

    for repo <- [nil, 42, "file:///tmp/repo", "https://user:password@example.com/repo", "https://example.com/repo?token=secret", "https://example.com/repo\ninjected", "-u"] do
      assert {:error, :invalid_plane_projects} = Plane.validate_config(put_in(tracker.provider["projects"], [Map.put(first, "repo", repo)]))
    end

    for duplicate <- [Map.put(second, "project_id", @project), Map.put(second, "project_identifier", "SY")] do
      duplicated = put_in(tracker.provider["projects"], [first, duplicate])
      assert {:error, :duplicate_plane_projects} = Plane.validate_config(duplicated)
    end

    assert {:error, :ambiguous_plane_projects} = Plane.validate_config(put_in(tracker.provider["project_id"], @project))
    assert :ok = Plane.validate_config(legacy)
    assert {:ok, %{native_ref: %{"project_id" => @project} = ref}} = Plane.normalize_issue(raw(), legacy)
    refute Map.has_key?(ref, "repo_url")
  end

  defp multi_tracker(tracker) do
    projects = [
      %{"project_id" => @project, "project_identifier" => "SY", "repo" => "https://github.com/example/first.git"},
      %{"project_id" => @other_project, "project_identifier" => "WEB", "repo" => "git@example.com:team/second.git"}
    ]

    %{tracker | provider: tracker.provider |> Map.drop(["project_id", "project_identifier"]) |> Map.put("projects", projects)}
  end

  defp install_tracker(tracker) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: plane
      provider: #{Jason.encode!(tracker.provider)}
      active_states: [Todo, In Progress]
      terminal_states: [Done, Cancelled]
      required_labels: [agent]
    polling:
      interval_ms: 3600000
    ---
    Test
    """)

    :ok = WorkflowStore.force_reload()
  end

  defp other_raw, do: Map.merge(raw(), %{"id" => @other_issue, "project" => @other_project})

  defp blocker_relation(project_id) do
    %{
      "issue_id" => @other_issue,
      "project_id" => project_id
    }
  end

  defp raw do
    %{
      "id" => @issue,
      "project" => @project,
      "name" => "Run smoke test",
      "sequence_id" => 1,
      "state" => %{"name" => "Todo"},
      "labels" => [%{"name" => " Agent "}],
      "priority" => "high",
      "description_html" => "<p>Test</p>"
    }
  end

  defp tool(tracker, arguments) do
    Plane.execute_agent_tool("plane", Map.merge(%{"issue_id" => @issue}, arguments), tracker_settings: tracker, issue: %Issue{id: @issue})
  end

  defp expect_issue(row \\ raw()) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert String.ends_with?(conn.request_path, "/work-items/#{@issue}/")
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["expand"] == "state,labels"
      Req.Test.json(conn, row)
    end)
  end

  defp expect_relations(issue_id \\ @issue, project_id \\ @project, blockers \\ []) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"

      assert conn.request_path ==
               "/api/v1/workspaces/demo/projects/#{project_id}/work-items/#{issue_id}/relations/"

      Req.Test.json(conn, %{"blocked_by" => blockers})
    end)
  end

  defp expect_project_issue(issue_id, project_id, row) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"

      assert conn.request_path ==
               "/api/v1/workspaces/demo/projects/#{project_id}/work-items/#{issue_id}/"

      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["expand"] == "state,labels"
      Req.Test.json(conn, row)
    end)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
