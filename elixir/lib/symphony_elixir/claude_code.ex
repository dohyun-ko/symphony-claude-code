defmodule SymphonyElixir.ClaudeCode do
  @moduledoc """
  Client for Claude Code CLI. Spawns `claude` as a subprocess and communicates
  via stdout stream-json lines.
  """

  require Logger
  alias SymphonyElixir.Config

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    with :ok <- validate_workspace_cwd(workspace),
         {:ok, port} <- start_port(workspace, prompt) do
      metadata = port_metadata(port)
      session_id = generate_session_id()

      Logger.info("Claude Code session starting for #{issue_context(issue)} session_id=#{session_id}")

      emit_message(on_message, :session_started, %{session_id: session_id}, metadata)

      result = receive_loop(port, on_message, Config.codex_turn_timeout_ms(), "", metadata)

      case result do
        {:ok, result_data} ->
          Logger.info("Claude Code session completed for #{issue_context(issue)} session_id=#{session_id}")
          {:ok, Map.put(result_data, :session_id, session_id)}

        {:error, reason} ->
          Logger.warning("Claude Code session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

          emit_message(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason}, metadata)
          {:error, reason}
      end
    end
  end

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())
    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace_cwd, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  defp start_port(workspace, prompt) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      command = build_claude_command(prompt)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            env: build_env(),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp build_claude_command(prompt) do
    base_command = Config.codex_command()
    escaped_prompt = prompt |> String.replace("'", "'\\''")
    "#{base_command} '#{escaped_prompt}'"
  end

  defp build_env do
    env = [
      {~c"CLAUDECODE", ~c""},
      {~c"DISABLE_PROMPT_CACHING", ~c"1"}
    ]

    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> env
      key -> [{~c"ANTHROPIC_API_KEY", String.to_charlist(key)} | env]
    end
  end

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
      _ -> %{}
    end
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, metadata) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_line(port, on_message, complete_line, timeout_ms, metadata)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, timeout_ms, pending_line <> to_string(chunk), metadata)

      {^port, {:exit_status, 0}} ->
        {:ok, %{result: :completed}}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_line(port, on_message, data, timeout_ms, metadata) do
    case Jason.decode(data) do
      {:ok, %{"type" => "system", "subtype" => "init"} = payload} ->
        session_id = Map.get(payload, "session_id")
        metadata = Map.put(metadata, :claude_session_id, session_id)

        emit_message(on_message, :session_started, %{
          session_id: session_id,
          payload: payload
        }, metadata)

        receive_loop(port, on_message, timeout_ms, "", metadata)

      {:ok, %{"type" => "assistant", "message" => message} = payload} ->
        usage = Map.get(message, "usage", %{})

        emit_message(on_message, :assistant_message, %{
          payload: payload,
          usage: usage,
          raw: data
        }, Map.merge(metadata, extract_usage_metadata(usage)))

        receive_loop(port, on_message, timeout_ms, "", metadata)

      {:ok, %{"type" => "tool_use"} = payload} ->
        emit_message(on_message, :tool_use, %{
          payload: payload,
          raw: data
        }, metadata)

        receive_loop(port, on_message, timeout_ms, "", metadata)

      {:ok, %{"type" => "tool_result"} = payload} ->
        emit_message(on_message, :tool_result, %{
          payload: payload,
          raw: data
        }, metadata)

        receive_loop(port, on_message, timeout_ms, "", metadata)

      {:ok, %{"type" => "rate_limit_event"} = payload} ->
        rate_limit_info = Map.get(payload, "rate_limit_info", %{})

        emit_message(on_message, :rate_limit, %{
          payload: payload,
          rate_limits: rate_limit_info
        }, metadata)

        receive_loop(port, on_message, timeout_ms, "", metadata)

      {:ok, %{"type" => "result", "subtype" => "success"} = payload} ->
        usage = Map.get(payload, "usage", %{})

        emit_message(on_message, :turn_completed, %{
          payload: payload,
          usage: usage,
          raw: data
        }, Map.merge(metadata, extract_usage_metadata(usage)))

        {:ok, %{
          result: :turn_completed,
          usage: usage,
          cost_usd: Map.get(payload, "total_cost_usd"),
          duration_ms: Map.get(payload, "duration_ms"),
          num_turns: Map.get(payload, "num_turns")
        }}

      {:ok, %{"type" => "result", "subtype" => "error"} = payload} ->
        emit_message(on_message, :turn_failed, %{
          payload: payload,
          raw: data
        }, metadata)

        {:error, {:turn_failed, Map.get(payload, "error", "unknown error")}}

      {:ok, %{"type" => "result", "is_error" => true} = payload} ->
        emit_message(on_message, :turn_failed, %{
          payload: payload,
          raw: data
        }, metadata)

        {:error, {:turn_failed, Map.get(payload, "error", "unknown error")}}

      {:ok, payload} ->
        emit_message(on_message, :notification, %{
          payload: payload,
          raw: data
        }, metadata)

        receive_loop(port, on_message, timeout_ms, "", metadata)

      {:error, _reason} ->
        log_non_json_line(data)
        receive_loop(port, on_message, timeout_ms, "", metadata)
    end
  end

  defp extract_usage_metadata(usage) when is_map(usage) do
    %{
      usage: %{
        "input_tokens" => Map.get(usage, "input_tokens", 0) + Map.get(usage, "cache_read_input_tokens", 0),
        "output_tokens" => Map.get(usage, "output_tokens", 0),
        "total_tokens" =>
          Map.get(usage, "input_tokens", 0) +
          Map.get(usage, "output_tokens", 0) +
          Map.get(usage, "cache_read_input_tokens", 0) +
          Map.get(usage, "cache_creation_input_tokens", 0)
      }
    }
  end

  defp extract_usage_metadata(_usage), do: %{}

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp log_non_json_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude Code output: #{text}")
      else
        Logger.debug("Claude Code output: #{text}")
      end
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp default_on_message(_message), do: :ok
end
