defmodule SymphonyElixir.AgentSession do
  @moduledoc """
  Chooses the coding-agent backend once per worker session: an ACP agent when
  `acp.command` is configured, otherwise the Codex app-server.
  """

  alias SymphonyElixir.{Acp, Codex.AppServer, Config}

  @type t :: %{backend: module(), session: map()}

  @spec start_session(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start_session(workspace, opts) do
    backend = backend()

    with {:ok, session} <- backend.start_session(workspace, opts) do
      {:ok, %{backend: backend, session: session}}
    end
  end

  @spec run_turn(t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{backend: backend, session: session}, prompt, issue, opts) do
    backend.run_turn(session, prompt, issue, opts)
  end

  @spec stop_session(t()) :: :ok
  def stop_session(%{backend: backend, session: session}), do: backend.stop_session(session)

  @spec backend() :: module()
  def backend do
    if is_binary(Config.settings!().acp.command), do: Acp, else: AppServer
  end
end
