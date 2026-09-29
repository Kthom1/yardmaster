defmodule SymphonyElixir.Plane do
  @moduledoc """
  Plane project adapter. Plane owns durable task state; Symphony owns execution.
  Repository routing comes only from the host's configured project mappings.
  The agent tool only reads tasks, posts comments, and changes workflow state.
  """

  @behaviour SymphonyElixir.Tracker
  require Logger
  alias SymphonyElixir.{Config, Tracker.Issue}
  alias SymphonyElixir.Config.Schema

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @states ["In Progress", "Human Review", "Blocked"]
  @priorities %{"urgent" => 1, "high" => 2, "medium" => 3, "low" => 4, "none" => 5}

  @impl true
  def validate_config(tracker) do
    p = tracker.provider

    with :ok <- validate_states(tracker) do
      validate_provider(tracker, p)
    end
  end

  defp validate_provider(tracker, p) do
    cond do
      not endpoint?(p["endpoint"]) ->
        {:error, :invalid_plane_endpoint}

      not optional_endpoint?(p["web_url"]) ->
        {:error, :invalid_plane_web_url}

      not matches?(p["workspace"], ~r/\A[a-zA-Z0-9_-]+\z/) ->
        {:error, :invalid_plane_workspace}

      not matches?(p["api_key"], ~r/\A\$[A-Z_][A-Z0-9_]*\z/) ->
        {:error, :plane_api_key_must_be_environment_reference}

      token(tracker) in [nil, ""] ->
        {:error, :missing_plane_api_key}

      true ->
        validate_projects(p)
    end
  end

  # Blocker gating and the agent workflow start from the Todo queue state.
  defp validate_states(tracker) do
    cond do
      not state_names?(tracker.active_states) -> {:error, :missing_plane_active_states}
      not state_names?(tracker.terminal_states) -> {:error, :missing_plane_terminal_states}
      not state_in?("Todo", tracker.active_states) -> {:error, :plane_active_states_must_include_todo}
      true -> :ok
    end
  end

  @impl true
  def secret_environment_names(tracker) do
    ["PLANE_API_KEY", String.trim_leading(tracker.provider["api_key"] || "", "$")]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @impl true
  def fetch_issues_by_states([]), do: {:ok, []}

  def fetch_issues_by_states(states) do
    tracker = Config.settings!().tracker

    with :ok <- validate_config(tracker),
         {:ok, issues} <- fetch_project_states(project_trackers(tracker), states) do
      enrich_dependencies(issues, tracker, :hold)
    end
  end

  defp fetch_project_states(projects, states) do
    Enum.reduce_while(projects, {:ok, []}, fn project, {:ok, acc} ->
      with {:ok, rows} <- pages(project, "work-items/", %{"expand" => "state,labels"}, [], []),
           {:ok, issues} <- normalize(rows, project, &state_in?(&1.state, states)) do
        {:cont, {:ok, acc ++ issues}}
      else
        error -> {:halt, error}
      end
    end)
  end

  @impl true
  def fetch_issues_by_ids(ids) do
    tracker = Config.settings!().tracker

    with :ok <- validate_config(tracker),
         {:ok, issues} <- fetch_ids(tracker, Enum.uniq(ids)) do
      enrich_dependencies(issues, tracker, :error)
    end
  end

  defp fetch_ids(tracker, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case fetch_issue(tracker, id) do
        {:ok, issues} -> {:cont, {:ok, acc ++ issues}}
        error -> {:halt, error}
      end
    end)
  end

  defp fetch_issue(tracker, id) do
    Enum.reduce_while(project_trackers(tracker), {:ok, []}, fn project, _acc ->
      case fetch_project_issue(project, id) do
        {:ok, []} -> {:cont, {:ok, []}}
        result -> {:halt, result}
      end
    end)
  end

  defp fetch_project_issue(tracker, id) do
    with true <- uuid?(id),
         {:ok, raw} <- request(tracker, :get, "work-items/#{id}/", %{"expand" => "state,labels"}),
         {:ok, %Issue{id: ^id} = issue} <- normalize_issue(raw, tracker) do
      {:ok, [issue]}
    else
      false -> {:error, :invalid_plane_issue_id}
      {:error, {:plane_http, 404}} -> {:ok, []}
      {:ok, _} -> {:error, :invalid_plane_issue}
      error -> error
    end
  end

  @spec normalize_issue(map(), map()) :: {:ok, Issue.t()} | {:error, atom()}
  def normalize_issue(%{"project" => project_id} = raw, tracker) do
    with {:ok, project} <- tracker_for_project(tracker, project_id) do
      normalize_project_issue(raw, project)
    end
  end

  def normalize_issue(_, _), do: {:error, :invalid_plane_issue}

  defp normalize_project_issue(raw, tracker) do
    p = tracker.provider

    case raw do
      %{"id" => id, "name" => name, "sequence_id" => sequence, "state" => %{"name" => state}, "project" => project, "labels" => labels}
      when is_binary(name) and is_integer(sequence) and is_binary(state) and is_list(labels) ->
        if valid_row?(raw, p) do
          identifier = "#{p["project_identifier"]}-#{sequence}"

          {:ok,
           %Issue{
             id: id,
             native_ref: native_ref(project, p["repo"]),
             identifier: identifier,
             title: name,
             description: raw["description_html"] || "",
             priority: Map.get(@priorities, raw["priority"]),
             state: state,
             url: "#{String.trim_trailing(p["web_url"] || p["endpoint"], "/")}/#{p["workspace"]}/browse/#{identifier}/",
             labels: Enum.map(labels, &String.downcase(String.trim(&1["name"]))),
             dispatchable: dispatchable?(raw),
             created_at: datetime(raw["created_at"]),
             updated_at: datetime(raw["updated_at"])
           }}
        else
          {:error, :invalid_plane_issue}
        end

      _ ->
        {:error, :invalid_plane_issue}
    end
  end

  @impl true
  def agent_tool_specs do
    [
      %{
        "name" => "plane",
        "description" =>
          "Read a Plane task and comments. Add comments or change state only on your assigned task while it is active and routed to this runner. Read before writing; never repeat an existing progress comment.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["action", "issue_id"],
          "properties" => %{
            "action" => %{"type" => "string", "enum" => ["read", "comment", "set_state"]},
            "issue_id" => %{"type" => "string", "description" => "The task UUID, supplied in the workflow prompt."},
            "text" => %{"type" => "string", "description" => "Plain-text comment. Include evidence and branch links."},
            "state" => %{"type" => "string", "enum" => @states}
          }
        }
      }
    ]
  end

  @impl true
  def execute_agent_tool("plane", %{"issue_id" => id} = args, opts) do
    tracker = Keyword.fetch!(opts, :tracker_settings)
    bound = Keyword.get(opts, :issue)

    result =
      with true <- uuid?(id),
           :ok <- validate_config(tracker),
           {:ok, project} <- tool_tracker(tracker, bound) do
        action(project, id, args, bound)
      else
        false -> {:error, :invalid_plane_issue_id}
        error -> error
      end

    tool_result(result)
  end

  def execute_agent_tool(_, _, _), do: tool_result({:error, :invalid_plane_tool_arguments})

  defp action(tracker, id, %{"action" => "read"}, _bound_issue) do
    with {:ok, issue} <- request(tracker, :get, "work-items/#{id}/", %{"expand" => "state,labels"}),
         {:ok, %Issue{id: ^id}} <- normalize_issue(issue, tracker),
         {:ok, comments} <- pages(tracker, "work-items/#{id}/comments/", %{}, [], []) do
      {:ok, %{"issue" => issue, "comments" => comments}}
    else
      {:ok, _} -> {:error, :invalid_plane_issue}
      error -> error
    end
  end

  defp action(tracker, id, %{"action" => "comment", "text" => text}, bound_issue)
       when is_binary(text) and byte_size(text) > 0 and byte_size(text) <= 32_000 do
    with {:ok, issue} <- bound_issue(tracker, id, bound_issue),
         :ok <- writable_issue(issue, tracker) do
      html = text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
      request(tracker, :post, "work-items/#{id}/comments/", %{}, %{"comment_html" => "<p>#{String.replace(html, "\n", "<br>")}</p>"})
    end
  end

  defp action(tracker, id, %{"action" => "set_state", "state" => state}, bound_issue) when state in @states do
    with {:ok, issue} <- bound_issue(tracker, id, bound_issue) do
      if state_in?(issue.state, [state]) do
        {:ok, %{"id" => issue.id, "state" => issue.state, "unchanged" => true}}
      else
        change_state(tracker, issue, state)
      end
    end
  end

  defp action(_, _, _, _), do: {:error, :invalid_plane_tool_arguments}

  defp change_state(tracker, issue, state) do
    with :ok <- writable_issue(issue, tracker),
         {:ok, state_id} <- state_id(tracker, state) do
      # ponytail: preflight is not atomic; use conditional writes if stronger cancellation is required.
      request(tracker, :patch, "work-items/#{issue.id}/", %{}, %{"state" => state_id})
    end
  end

  defp bound_issue(tracker, id, %{id: bound_id}) when id == bound_id do
    case fetch_issue(tracker, id) do
      {:ok, [issue]} -> {:ok, issue}
      {:ok, []} -> {:error, :plane_issue_not_found}
      error -> error
    end
  end

  defp bound_issue(_, _, _), do: {:error, :plane_issue_scope_mismatch}

  defp writable_issue(issue, tracker) do
    if Issue.routable?(issue, tracker.required_labels) and
         state_in?(issue.state, tracker.active_states) and not state_in?(issue.state, tracker.terminal_states) do
      :ok
    else
      {:error, :plane_issue_not_dispatchable}
    end
  end

  defp state_id(tracker, state) do
    with {:ok, states} <- pages(tracker, "states/", %{}, [], []),
         true <- Enum.all?(states, &valid_state?/1) do
      case Enum.filter(states, &state_in?(&1["name"], [state])) do
        [%{"id" => id}] -> {:ok, id}
        [] -> {:error, :missing_plane_workflow_state}
        _ -> {:error, :ambiguous_plane_workflow_state}
      end
    else
      false -> {:error, :invalid_plane_workflow_states}
      error -> error
    end
  end

  defp valid_state?(%{"id" => id, "name" => name}), do: uuid?(id) and is_binary(name) and String.trim(name) != ""
  defp valid_state?(_), do: false

  defp validate_projects(%{"projects" => projects} = provider) do
    cond do
      not is_list(projects) or projects == [] ->
        {:error, :invalid_plane_projects}

      Map.has_key?(provider, "project_id") or Map.has_key?(provider, "project_identifier") ->
        {:error, :ambiguous_plane_projects}

      not Enum.all?(projects, &valid_project_mapping?/1) ->
        {:error, :invalid_plane_projects}

      duplicate_field?(Enum.map(projects, &canonical_project/1), "project_id") or duplicate_field?(projects, "project_identifier") ->
        {:error, :duplicate_plane_projects}

      true ->
        :ok
    end
  end

  defp validate_projects(provider), do: validate_project(provider)

  defp valid_project_mapping?(%{"repo" => repo} = project), do: repo_url?(repo) and validate_project(project) == :ok
  defp valid_project_mapping?(_), do: false

  defp validate_project(project) do
    cond do
      not uuid?(project["project_id"]) -> {:error, :invalid_plane_project_id}
      not matches?(project["project_identifier"], ~r/\A[A-Z0-9_-]+\z/) -> {:error, :invalid_plane_project_identifier}
      not is_nil(project["repo"]) and not repo_url?(project["repo"]) -> {:error, :invalid_plane_repository}
      true -> :ok
    end
  end

  defp duplicate_field?(projects, key) do
    values = Enum.map(projects, & &1[key])
    length(values) != length(Enum.uniq(values))
  end

  # Plane state names are workspace-defined, so workflows must list them.
  defp state_names?(states), do: is_list(states) and states != [] and Enum.all?(states, &(is_binary(&1) and String.trim(&1) != ""))

  defp repo_url?(value) when is_binary(value) do
    not Regex.match?(~r/[\s\p{C}]/u, value) and
      (Regex.match?(~r|\Agit@[A-Za-z0-9.-]+:[A-Za-z0-9_./-]+\z|, value) or
         (String.starts_with?(value, "https://") and endpoint?(value)))
  end

  defp repo_url?(_), do: false

  defp project_trackers(%{provider: %{"projects" => projects} = provider} = tracker) do
    Enum.map(projects, fn project ->
      scoped = provider |> Map.delete("projects") |> Map.merge(Map.take(project, ["project_id", "project_identifier", "repo"]))
      %{tracker | provider: canonical_project(scoped)}
    end)
  end

  defp project_trackers(tracker), do: [%{tracker | provider: canonical_project(tracker.provider)}]

  # Plane reports project UUIDs in lowercase; configured ones may use any case.
  defp canonical_project(project), do: Map.replace_lazy(project, "project_id", &if(is_binary(&1), do: String.downcase(&1), else: &1))

  defp tracker_for_project(tracker, project_id) do
    case Enum.find(project_trackers(tracker), &(&1.provider["project_id"] == project_id)) do
      nil -> {:error, :invalid_plane_issue}
      project -> {:ok, project}
    end
  end

  defp native_ref(project_id, nil), do: %{"project_id" => project_id}
  defp native_ref(project_id, repo), do: %{"project_id" => project_id, "repo_url" => repo}

  defp tool_tracker(tracker, %{native_ref: %{"project_id" => id} = ref}) do
    with {:ok, project} <- tracker_for_project(tracker, id),
         true <- Map.get(ref, "repo_url") == project.provider["repo"] do
      {:ok, project}
    else
      _ -> {:error, :plane_issue_scope_mismatch}
    end
  end

  # Legacy single-project callers did not need native_ref to select a project.
  defp tool_tracker(%{provider: provider} = tracker, _) do
    if Map.has_key?(provider, "projects") do
      {:error, :plane_issue_scope_mismatch}
    else
      {:ok, %{tracker | provider: canonical_project(provider)}}
    end
  end

  defp enrich_dependencies(issues, tracker, error_mode) do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      case enrich_issue_dependencies(issue, tracker) do
        {:ok, enriched} ->
          {:cont, {:ok, [enriched | acc]}}

        {:error, reason} when error_mode == :hold ->
          Logger.warning("Plane dependency lookup failed; holding task issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")

          {:cont, {:ok, [%{issue | dispatchable: false} | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, enriched} -> {:ok, Enum.reverse(enriched)}
      error -> error
    end
  end

  defp enrich_issue_dependencies(issue, tracker) do
    if state_in?(issue.state, ["Todo"]) and Issue.routable?(issue, tracker.required_labels),
      do: issue_dependencies(issue, tracker),
      else: {:ok, issue}
  end

  defp issue_dependencies(%Issue{native_ref: %{"project_id" => project_id}} = issue, tracker) do
    with {:ok, project} <- tracker_for_project(tracker, project_id),
         {:ok, relations} <- request(project, :get, "work-items/#{issue.id}/relations/", %{}),
         {:ok, blockers} <- normalize_blockers(relations, tracker) do
      {:ok,
       %{
         issue
         | blocked_by: blockers,
           dispatchable: issue.dispatchable and not blocked_before_dispatch?(issue.state, blockers, tracker.terminal_states)
       }}
    end
  end

  defp normalize_blockers(%{"blocked_by" => blockers}, tracker) when is_list(blockers) do
    Enum.reduce_while(blockers, {:ok, []}, fn blocker, {:ok, acc} ->
      case normalize_blocker(blocker, tracker) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_blockers(_, _), do: {:error, :invalid_plane_issue_relations}

  defp normalize_blocker(%{"issue_id" => id, "project_id" => project_id}, tracker) do
    if uuid?(id) and uuid?(project_id) do
      resolve_blocker(id, project_id, tracker)
    else
      {:error, :invalid_plane_issue_relations}
    end
  end

  defp normalize_blocker(_, _), do: {:error, :invalid_plane_issue_relations}

  defp resolve_blocker(id, project_id, tracker) do
    case tracker_for_project(tracker, project_id) do
      {:ok, project} ->
        with {:ok, raw} <- request(project, :get, "work-items/#{id}/", %{"expand" => "state,labels"}),
             {:ok, %Issue{id: ^id, native_ref: %{"project_id" => ^project_id}} = issue} <- normalize_issue(raw, tracker) do
          {:ok, %{id: id, identifier: issue.identifier, state: issue.state}}
        else
          {:ok, _} -> {:error, :invalid_plane_issue_relations}
          error -> error
        end

      {:error, :invalid_plane_issue} ->
        {:ok, %{id: id, identifier: nil, state: nil}}
    end
  end

  defp blocked_before_dispatch?(state, blockers, terminal_states) do
    state_in?(state, ["Todo"]) and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) -> not state_in?(blocker_state, terminal_states)
        _ -> true
      end)
  end

  defp state_in?(state, states), do: Enum.any?(states, &(Schema.normalize_issue_state(&1) == Schema.normalize_issue_state(state)))

  defp normalize(raw, tracker, predicate) do
    Enum.reduce_while(raw, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_issue(item, tracker) do
        {:ok, issue} -> {:cont, {:ok, if(predicate.(issue), do: [issue | acc], else: acc)}}
        error -> {:halt, error}
      end
    end)
  end

  defp pages(tracker, path, query, acc, seen) do
    with {:ok, body} <- request(tracker, :get, path, query) do
      case body do
        %{"results" => results, "next_page_results" => true, "next_cursor" => cursor}
        when is_list(results) and is_binary(cursor) and cursor != "" ->
          next_page(tracker, path, query, acc ++ results, seen, cursor)

        %{"results" => results, "next_page_results" => false} when is_list(results) ->
          {:ok, acc ++ results}

        results when is_list(results) ->
          {:ok, acc ++ results}

        _ ->
          {:error, :invalid_plane_page}
      end
    end
  end

  defp next_page(tracker, path, query, acc, seen, cursor) do
    if cursor in seen do
      {:error, :plane_repeated_cursor}
    else
      pages(tracker, path, Map.put(query, "cursor", cursor), acc, [cursor | seen])
    end
  end

  defp endpoint?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, uri} ->
        uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and uri.port in 1..65_535 and
          is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)

      {:error, _} ->
        false
    end
  end

  defp endpoint?(_), do: false
  defp optional_endpoint?(value), do: is_nil(value) or endpoint?(value)

  defp matches?(value, pattern), do: is_binary(value) and Regex.match?(pattern, value)

  defp valid_row?(raw, provider) do
    uuid?(raw["id"]) and raw["project"] == provider["project_id"] and
      String.trim(raw["name"]) != "" and
      Enum.all?(raw["labels"], &match?(%{"name" => label} when is_binary(label), &1))
  end

  defp dispatchable?(raw), do: is_nil(raw["archived_at"]) and is_nil(raw["deleted_at"]) and raw["is_draft"] != true

  defp request(tracker, method, path, query, body \\ nil) do
    p = tracker.provider
    url = "#{String.trim_trailing(p["endpoint"], "/")}/api/v1/workspaces/#{p["workspace"]}/projects/#{p["project_id"]}/#{path}"

    opts = [
      method: method,
      url: url,
      params: query,
      headers: [{"x-api-key", token(tracker)}],
      receive_timeout: 15_000,
      retry: false,
      redirect: false
    ]

    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)
    opts = Keyword.merge(opts, Application.get_env(:symphony_elixir, :plane_req_options, []))

    case Req.request(opts) do
      {:ok, %{status: status, body: response}} when status in 200..299 -> {:ok, response}
      {:ok, %{status: status}} -> {:error, {:plane_http, status}}
      {:error, _} -> {:error, :plane_transport_error}
    end
  end

  defp tool_result(result) do
    {success, payload} =
      case result do
        {:ok, body} -> {true, body}
        {:error, reason} -> {false, %{"error" => inspect(reason)}}
      end

    output = Jason.encode!(payload)
    %{"success" => success, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  defp token(tracker), do: System.get_env(String.trim_leading(tracker.provider["api_key"], "$"))

  defp uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp datetime(_), do: nil
end
