# Yardmaster

Yardmaster turns work items on a task board into isolated, unattended coding-agent runs. It polls
a tracker, gives each eligible work item its own workspace, runs a coding agent there, retries
failed runs and serves a live dashboard. The work item stays the source of truth; the agent reports
progress and hands the result back for review.

Yardmaster is a modified version of [OpenAI Symphony](https://github.com/openai/symphony). It keeps
Symphony's [specification](SPEC.md), workflow format and trackers, and adds:

- **Any Agent Client Protocol agent.** Run Codex, or set `acp.command` to run an
  [ACP](https://agentclientprotocol.com) agent such as Claude Code. Tracker tools reach every agent
  the same way, and tracker credentials never enter the agent's environment.
- **An agent sandbox.** `scripts/agent-sandbox` runs any agent with the host read-only except its
  workspace, `/tmp` and paths you name.
- **A Plane tracker** with project-to-repository mappings and blocking-relation gating.
- **Reliability fixes**: turn-event correlation, task-specific Git directories in sandbox policies,
  and patched dependency versions.

> [!WARNING]
> Yardmaster is early software for trusted environments. Agents run unattended with your user's
> permissions and network access. Use trusted repositories and work-item authors.

## Get started

See [elixir/README.md](elixir/README.md) for requirements, configuration and running the service.
[Agent Client Protocol agents](elixir/README.md#agent-client-protocol-agents) covers Claude Code and
other ACP agents.

The Elixir application keeps its upstream module names (`SymphonyElixir`) so upstream changes stay
easy to merge. The executable is `yardmaster`.

## License

Yardmaster is licensed under the [Apache License 2.0](LICENSE). It includes OpenAI Symphony,
copyright 2025 OpenAI; see [NOTICE](NOTICE).
