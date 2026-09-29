defmodule SymphonyElixir.AgentSandboxTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../scripts/agent-sandbox", __DIR__)
  @usable is_binary(System.find_executable("bwrap")) and
            match?({_, 0}, System.cmd("bwrap", ["--ro-bind", "/", "/", "true"], stderr_to_stdout: true))

  unless @usable, do: @moduletag(skip: "bubblewrap with unprivileged user namespaces is unavailable")

  @tag :tmp_dir
  test "only the checkout, /tmp and named paths are writable", %{tmp_dir: tmp_dir} do
    checkout = Path.join(tmp_dir, "checkout")
    state = Path.join(tmp_dir, "state")
    File.mkdir_p!(checkout)
    File.mkdir_p!(state)
    outside = Path.join(File.cwd!(), "_build/agent-sandbox-escape-#{System.unique_integer([:positive])}")

    script = "echo in > inside && echo state > #{state}/file && (echo out > #{outside}) 2>/dev/null; echo done"
    assert {"done\n", 0} = System.cmd(@script, ["--writable", state, "--", "sh", "-c", script], cd: checkout)
    assert File.read!(Path.join(checkout, "inside")) == "in\n"
    assert File.read!(Path.join(state, "file")) == "state\n"
    refute File.exists?(outside)
  end

  test "relative writable paths and home-directory runs are refused" do
    assert {_output, status} = System.cmd(@script, ["--writable", "relative", "--", "true"], cd: System.tmp_dir!(), stderr_to_stdout: true)
    assert status != 0
    assert {_output, status} = System.cmd(@script, ["--", "true"], cd: System.user_home!(), stderr_to_stdout: true)
    assert status != 0
  end
end
