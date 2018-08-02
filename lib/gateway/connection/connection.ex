defmodule Crux.Gateway.Connection do
  @moduledoc """
  Handles the actual connection to Discord.
  """

  use WebSockex

  alias Crux.Gateway.Command
  alias Crux.Gateway.Connection.{Producer, RateLimiter}

  require Logger

  @hello_timeout 20_000
  @hello_timeout_message "Did not receive hello after 20 seconds"

  @heartbeat_timeout 20_000
  @heartbeat_timeout_message "Did not receive heartbeat ack after 20 seconds"

  @registry Crux.Gateway.Registry

  @doc """
    Sends a command to the specified shard.

    The command will be run through a rate limiter, this blockes the calling process until the command is sent.
  """
  @spec send_command(command :: WebSockex.Frame.t(), shard_id :: non_neg_integer()) ::
          :ok | {:error, term()}
  def send_command({atom, _command} = command, shard_id) when is_number(shard_id) do
    with {^atom, _command} <- RateLimiter.queue(command, shard_id),
         [{pid, _other}] when is_pid(pid) <- Registry.lookup(@registry, {shard_id, :connection}),
         true <- Process.alive?(pid) do
      if pid == self(),
        do: spawn(fn -> WebSockex.send_frame(pid, command) end),
        else: WebSockex.send_frame(pid, command)
    else
      _ ->
        {:error, :not_found}
    end
  end

  @doc false
  def start_link(%{shard_id: shard_id, url: url} = args) do
    # yes "/?"
    url = "#{url}/?encoding=etf&v=6&compress=zlib-stream"

    Logger.info("[Crux][Gateway][Shard #{shard_id}]: Booting, connecting to #{url}")

    WebSockex.start_link(url, __MODULE__, [args])
  end

  @doc false
  def handle_connect(_, [%{shard_id: shard_id} = args]) do
    Logger.info("[Crux][Gateway][Shard #{shard_id}]: Connected")

    # WebSockex does not support `:via` regestration with start_link (yet).
    Registry.register(@registry, {shard_id, :connection}, self())

    z = :zlib.open()
    :zlib.inflateInit(z)

    {:ok, ref} = :timer.send_after(@hello_timeout, :hello_timeout)

    state =
      args
      |> Map.put(:zlib, {<<>>, z})
      |> Map.put(:hello_timeout, ref)

    {:ok, state}
  end

  def handle_connect(_, %{shard_id: shard_id} = state) do
    Logger.info("[Crux][Gateway][Shard #{shard_id}]: Reconnected")

    # A new context seems to be required
    z = :zlib.open()
    :zlib.inflateInit(z)

    {:ok, ref} = :timer.send_after(@hello_timeout, :hello_timeout)

    state =
      state
      |> Map.put(:zlib, {<<>>, z})
      |> Map.put(:hello_timeout, ref)

    {:ok, state}
  end

  @doc false
  def handle_disconnect(%{reason: {:remote, code, reason}}, %{shard_id: shard_id} = state) do
    Logger.warn("[Crux][Gateway][Shard #{shard_id}]: Disconnected: #{code} - \"#{reason}\"")

    {:reconnect, state}
  end

  def handle_disconnect(
        %{reason: {:local, 4000, message}},
        %{shard_id: shard_id} = state
      )
      when message in [
             @heartbeat_timeout_message,
             @hello_timeout_message
           ] do
    Logger.warn(
      "[Crux][Gateway][Shard #{shard_id}]: Disconnected: #{message}. Waiting five seconds before reconnecting"
    )

    :timer.sleep(5_000)

    {:reconnect, state}
  end

  def handle_disconnect(%{reason: reason}, %{shard_id: shard_id} = state) do
    Logger.warn(
      "[Crux][Gateway][Shard #{shard_id}]: Disconnected: #{inspect(reason)}. Waiting five seconds before reconnecting"
    )

    :timer.sleep(5_000)

    {:reconnect, state}
  end

  def handle_disconnect(other, %{shard_id: shard_id} = state) do
    Logger.warn(
      "[Crux][Gateway][Shard #{shard_id}]: Disconnected: #{inspect(other)}. Waiting five seconds before reconnecting"
    )

    :timer.sleep(5_000)

    {:reconnect, state}
  end

  @doc false
  def handle_info(:stop, state), do: {:close, {1000, "Closing connection"}, state}
  def handle_info({:send, {_atom, _command} = data}, state), do: {:reply, data, state}

  def handle_info(:heartbeat, %{shard_id: shard_id} = state) do
    Logger.debug(
      "[Crux][Gateway][Shard #{shard_id}]: Sending heartbeat at seq #{Map.get(state, :seq, "nil")}"
    )

    state
    |> Map.get(:seq)
    |> Command.heartbeat()
    |> send_command(shard_id)

    {:ok, ref} = :timer.send_after(@heartbeat_timeout, :heartbeat_timeout)

    {:ok, Map.put(state, :heartbeat_timeout, ref)}
  end

  def handle_info(:heartbeat_timeout, state) do
    {:close, {4000, @heartbeat_timeout_message}, state}
  end

  def handle_info(:hello_timeout, state) do
    {:close, {4000, @hello_timeout_message}, state}
  end

  def handle_info(other, %{shard_id: shard_id} = state) do
    Logger.warn(
      "[Crux][Gateway][Shard #{shard_id}]: Received unexpected message: #{inspect(other)}"
    )

    {:ok, state}
  end

  @doc false
  def terminate(reason, %{shard_id: shard_id}) do
    Logger.warn("[Crux][Gateway][Shard #{shard_id}]: Terminating due to #{inspect(reason)}")
  end

  @doc false
  def handle_frame({:binary, frame}, %{zlib: {buffer, z}} = state) do
    buffer = buffer <> frame
    # Get the last 4 bytes
    data_size = byte_size(buffer) - 4
    <<_data::binary-size(data_size), suffix::binary>> = buffer

    {buffer, packet} =
      if suffix == <<0, 0, 255, 255>> do
        uncompressed =
          buffer
          |> (&:zlib.inflate(z, &1)).()
          |> :erlang.iolist_to_binary()
          |> :erlang.binary_to_term()
          |> Crux.Gateway.Util.atomify()

        {<<>>, uncompressed}
      else
        {buffer, nil}
      end

    state =
      if packet do
        state
        |> handle_sequence(packet)
        |> handle_packet(packet)
      else
        state
      end

    {:ok, Map.put(state, :zlib, {buffer, z})}
  end

  defp handle_sequence(%{seq: seq} = state, %{s: s})
       when is_number(s) and is_number(seq) and s > seq,
       do: Map.put(state, :seq, s)

  defp handle_sequence(%{seq: seq} = state, _packet) when not is_nil(seq), do: state
  defp handle_sequence(state, %{s: s}), do: Map.put(state, :seq, s)
  defp handle_sequence(state, _packet), do: state

  defp handle_packet(%{shard_id: shard_id} = state, %{op: 0} = packet) do
    state =
      case packet.t do
        :READY ->
          Map.put(state, :session, packet.d.session_id)

        :RESUMED ->
          {close_seq, state} = Map.pop(state, :close_seq, 0)

          Logger.info(
            "[Crux][Gateway][Shard #{shard_id}]: Resumed #{close_seq} -> #{Map.get(state, :seq)}"
          )

          state

        _ ->
          state
      end

    Producer.dispatch(packet, shard_id)

    state
  end

  # 1 - Heartbeat
  defp handle_packet(state, %{op: 1}) do
    {:ok, state} = handle_info(:heartbeat, state)

    state
  end

  # 7 - Reconnect
  defp handle_packet(state, %{op: 7}) do
    send(self(), :stop)

    state
  end

  # 9 - Invalid Session - Resume
  defp handle_packet(%{shard_id: shard_id, seq: _seq, session: _session} = state, %{
         op: 9,
         d: true
       }) do
    Logger.warn("[Crux][Gateway][Shard #{shard_id}]: Invalid session, will try to resume")

    # Wait 5.5 seconds before resuming
    :timer.sleep(5_500)

    state
    |> Command.resume()
    |> send_command(shard_id)

    state
  end

  # 9 - Invalid Session - New
  defp handle_packet(%{shard_id: shard_id} = state, %{op: 9}) do
    Logger.warn("[Crux][Gateway][Shard #{shard_id}]: Invalid session, will identify as a new one")

    state =
      state
      |> Map.delete(:seq)
      |> Map.delete(:session)

    pid = self()

    spawn(fn ->
      command =
        state
        |> Command.identify()
        |> RateLimiter.queue(shard_id)
        |> Crux.Gateway.IdentifyLimiter.queue(shard_id)

      WebSockex.send_frame(pid, command)
    end)

    state
  end

  # 10 - Hello - Removeing hello timeout
  defp handle_packet(%{hello_timeout: ref} = state, %{op: 10} = packet) do
    :timer.cancel(ref)

    state
    |> Map.delete(:hello_timeout)
    |> handle_packet(packet)
  end

  # 10 - Hello - Still heartbeating
  defp handle_packet(%{heartbeat: ref} = state, %{op: 10} = packet) when not is_nil(ref) do
    :timer.cancel(ref)

    state
    |> Map.drop([:heartbeat])
    |> handle_packet(packet)
  end

  # 10 - Hello
  defp handle_packet(%{shard_id: shard_id} = state, %{op: 10, d: d}) do
    case state do
      %{seq: _seq, session: _session} ->
        Command.resume(state)
        |> send_command(shard_id)

      _ ->
        pid = self()

        spawn(fn ->
          command =
            state
            |> Command.identify()
            |> RateLimiter.queue(shard_id)
            |> Crux.Gateway.IdentifyLimiter.queue(shard_id)

          WebSockex.send_frame(pid, command)
        end)
    end

    {:ok, ref} =
      :timer.send_interval(
        d.heartbeat_interval,
        :heartbeat
      )

    Map.put(state, :heartbeat, ref)
  end

  # 11 - Heartbeat ack
  defp handle_packet(%{shard_id: shard_id} = state, %{op: 11}) do
    Logger.debug("[Crux][Gateway][Shard #{shard_id}]: Received heartbeat ack")

    case state do
      %{heartbeat_timeout: ref} ->
        :timer.cancel(ref)
        Map.delete(state, :heartbeat_timeout)

      state ->
        state
    end
  end

  defp handle_packet(%{shard_id: shard_id} = state, packet) do
    Logger.warn(
      "[Crux][Gateway][Shard #{shard_id}]: Unhandled packet type #{packet.t || packet.d}: #{
        inspect(packet)
      }"
    )

    state
  end
end
