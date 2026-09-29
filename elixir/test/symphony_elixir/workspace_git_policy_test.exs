defmodule SymphonyElixir.WorkspaceGitPolicyTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Config.Schema

  @policy %{"type" => "workspaceWrite", "writableRoots" => ["$WORKSPACE/.git", "/srv/cache"]}

  test "the Git directory token resolves to the workspace's own .git path" do
    settings = put_in(Config.settings!().codex.turn_sandbox_policy, @policy)
    assert {:ok, resolved} = Schema.resolve_runtime_turn_sandbox_policy(settings, "/tmp/task-SY-1")
    assert resolved["writableRoots"] == ["/tmp/task-SY-1/.git", "/srv/cache"]
    assert {:ok, @policy} = Schema.resolve_runtime_turn_sandbox_policy(settings, nil)
  end

  @tag :tmp_dir
  test "a .git file pointing elsewhere does not widen the writable roots", %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "task-SY-2")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, ".git"), "gitdir: #{System.user_home!()}\n")

    settings = put_in(Config.settings!().codex.turn_sandbox_policy, @policy)
    assert {:ok, resolved} = Schema.resolve_runtime_turn_sandbox_policy(settings, workspace)
    assert resolved["writableRoots"] == [Path.join(workspace, ".git"), "/srv/cache"]
  end
end
