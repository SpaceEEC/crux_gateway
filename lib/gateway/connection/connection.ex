defmodule Crux.Gateway.Connection do
  @moduledoc """
    Module handling the actual connection (shard) to Discord.
  """
  alias Crux.Gateway
  alias Crux.Gateway.{Connection, Command, IdentifyLimiter, Util}
  alias Crux.Gateway.Connection.{RateLimiter, Producer}

  use WebSockex

  require Logger

  @resume_timeout 5_000 + 500

  @hello_timeout 20_000
  @hello_timeout_message "Did not receive hello after 20 seconds"

  @heartbeat_timeout 20_000
  @heartbeat_timeout_message "Did not receive heartbeat ack after 20 seconds"

  @doc false
  @spec start_link(args :: map()) :: {:ok, pid} | {:error, term}
  def start_link(%{url: url, shard_id: shard_id} = args) do
    url = "#{url}/?encoding=etf&v=6&compress=zlib-stream"

    Logger.info(fn -> "[Crux][Gateway][Shard #{shard_id}}: Booting, connecting to #{url}" end)

    WebSockex.start_link(url, __MODULE__, [args])
  end

  @doc """
    Sends a command to the specified shard.

  > Will be run through a rate limiter which blocks the current process.
  """
  @spec send_command(
          gateway :: Crux.Gateway.gateway(),
          shard_id :: pos_integer(),
          command :: Crux.Gateway.Command.command()
        ) :: :ok

  def send_command(gateway, shard_id, command) do
    sup = Gateway.get_shard(gateway, shard_id)

    RateLimiter.queue(sup)

    sup
    |> Connection.Supervisor.get_connection()
    |> WebSockex.send_frame(command)
  end

  defp self_send(command, sup, gateway \\ nil) do
    con = self()

    spawn(fn ->
      RateLimiter.queue(sup)

      if gateway do
        IdentifyLimiter.queue(gateway)
      end

      WebSockex.send_frame(con, command)
    end)
  end

  @doc false
  def handle_connect(con, [%{shard_id: shard_id} = args]) do
    Logger.info(fn -> "[Crux][Gateway][Shard #{shard_id}]: Connected" end)

    handle_connect(con, args)
  end

  def handle_connect(con, %{shard_id: shard_id, zlib: {_, z}} = state) do
    Logger.info(fn -> "[Crux][Gateway][Shard #{shard_id}]: Reconnected" end)

    :zlib.inflateEnd(z)
    :zlib.close(z)

    state = Map.delete(state, :zlib)

    handle_connect(con, state)
  end

  def handle_connect(_, state) do
    {:ok, ref} = :timer.send_after(@hello_timeout, :hello_timer)

    z = :zlib.open()
    :zlib.inflateInit(z)

    state =
      state
      |> Map.put(:zlib, {<<>>, z})
      |> Map.put(:hello_timeout, ref)

    {:ok, state}
  end

  def handle_disconnect(reason, %{hello_timeout: ref} = state) do
    if ref do
      :timer.cancel(ref)
    end

    state = Map.delete(state, :hello_timeout)

    handle_disconnect(reason, state)
  end

  def handle_disconnect(reason, %{heartbeat: ref} = state) do
    if ref do
      :timer.cancel(ref)
    end

    state = Map.delete(state, :heartbeat)

    handle_disconnect(reason, state)
  end

  def handle_disconnect(reason, %{heartbeat_timeout: ref} = state) do
    if ref do
      :timer.cancel(ref)
    end

    state = Map.delete(state, :heartbeat_timeout)

    handle_disconnect(reason, state)
  end

  def handle_disconnect(%{reason: {:remote, code, reason}}, %{shard_id: shard_id} = state) do
    Logger.warn(fn ->
      "[Crux][Gateway][Shard #{shard_id}]: Disconnected: #{code} - \"#{reason}\""
    end)

    seq = Map.get(state, :seq, 0)
    state = Map.put(state, :close_seq, seq)

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
    Logger.warn(fn ->
      "[Crux][Gateway][Shard #{shard_id}]: Disconnected: #{message}. Waiting five seconds before reconnecting"
    end)

    seq = Map.get(state, :seq, 0)
    state = Map.put(state, :close_seq, seq)

    :timer.sleep(5_000)

    {:reconnect, state}
  end

  def handle_disconnect(reason, %{shard_id: shard_id} = state) do
    reason = Map.get(reason, :reason, reason)

    Logger.warn(fn ->
      "[Crux][Gateway][Shard #{shard_id}]: Disconnected: #{inspect(reason)}. Waiting five seconds before reconnecting"
    end)

    state = Map.put(state, :close_seq, Map.get(state, :seq, 0))

    :timer.sleep(5_000)

    {:reconnect, state}
  end

  @doc false
  def handle_info(:stop, state), do: {:close, {1000, "Closing connection"}, state}
  def handle_info({:send, frame}, state), do: {:reply, frame, state}

  def handle_info(:heartbeat, %{sup: sup, shard_id: shard_id} = state) do
    Logger.debug(fn ->
      "[Crux][Gateway][Shard #{shard_id}]: Sending heartbeat at seq #{Map.get(state, :seq, "nil")}"
    end)

    command =
      state
      |> Map.get(:seq)
      |> Command.heartbeat()

    self_send(command, sup)

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
    Logger.warn(fn ->
      "[Crux][Gateway][Shard #{shard_id}]: Received unexpected message: #{inspect(other)}"
    end)

    {:ok, state}
  end

  @doc false
  def terminate(reason, %{shard_id: shard_id}) do
    Logger.warn(fn ->
      "[Crux][Gateway][Shard #{shard_id}]: Terminating due to #{inspect(reason)}"
    end)
  end

  @doc false
  def handle_frame({:binary, frame}, %{zlib: {buffer, z}} = state) do
    frame_size = byte_size(frame) - 4
    <<_data::binary-size(frame_size), suffix::binary>> = frame

    buffer = buffer <> frame

    {vuffer, packet} =
      if suffix == <<0, 0, 255, 255>> do
        uncompressed =
          buffer
          |> (&:zlib.inflate(z, &1)).()
          |> :erlang.iolist_to_binary()
          |> :erlang.binary_to_term()
          |> Util.atomify()

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

    state = %{state | zlib: {vuffer, z}}

    {:ok, state}
  end

  defp handle_sequence(%{seq: seq} = state, %{s: s})
       when is_number(s) and is_number(seq) and s > seq
       when is_nil(seq) do
    %{state | seq: s}
  end

  defp handle_sequence(%{seq: seq} = state, _packet) when not is_nil(seq), do: state
  defp handle_sequence(state, %{s: s}), do: Map.put(state, :seq, s)
  defp handle_sequence(state, _packet), do: state

  defp handle_packet(
         %{sup: sup, shard_id: shard_id} = state,
         %{
           t: :READY,
           d: %{
             _trace: trace,
             session_id: session_id
           }
         } = packet
       ) do
    Logger.info(fn ->
      "[Crux][Gateway][Shard #{shard_id}]: Ready #{packet.d._trace |> Enum.join(" -> ")}"
    end)

    Producer.dispatch(sup, packet, shard_id)

    state
    |> Map.delete(:close_seq)
    |> Map.put(:trace, trace)
    |> Map.put(:session, session_id)
  end

  defp handle_packet(%{sup: sup, shard_id: shard_id} = state, %{t: :RESUMED} = packet) do
    {close_seq, state} = Map.pop(state, :close_seq, 0)

    Logger.info(fn ->
      "[Crux][Gateway][Shard #{shard_id}]: Resumed #{close_seq} -> #{Map.get(state, :seq)}"
    end)

    Producer.dispatch(sup, packet, shard_id)

    state
  end

  # Dispatch
  defp handle_packet(%{sup: sup, shard_id: shard_id} = state, %{op: 0} = packet) do
    Producer.dispatch(sup, packet, shard_id)

    state
  end

  # 1 - Heartbeat request
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
  defp handle_packet(%{sup: sup, shard_id: shard_id, seq: _seq, session: _session} = state, %{
         op: 9,
         d: true
       }) do
    Logger.warn(fn ->
      "[Crux][Gateway][Shard #{shard_id}]: Invalid session, will try to resume"
    end)

    :timer.sleep(@resume_timeout)

    command = Command.resume(state)

    self_send(command, sup)

    state
  end

  # 9 - Invalid Session - New
  defp handle_packet(%{gateway: gateway, sup: sup, shard_id: shard_id} = state, %{op: 9}) do
    Logger.warn(fn ->
      "[Crux][Gateway][Shard #{shard_id}]: Invalid session, will identify as a new one"
    end)

    state =
      state
      |> Map.delete(:seq)
      |> Map.delete(:session)

    state
    |> Command.identify()
    |> self_send(sup, gateway)

    state
  end

  # 10 - Hello - Removing hello timeout
  defp handle_packet(%{hello_timeout: ref} = state, %{op: 10} = packet) do
    if ref do
      :timer.cancel(ref)
    end

    state
    |> Map.delete(:hello_timeout)
    |> handle_packet(packet)
  end

  # 10 - Hello - Still heartbeating
  defp handle_packet(%{heartbeat: ref} = state, %{op: 10} = packet) when not is_nil(ref) do
    if ref do
      :timer.cancel(ref)
    end

    state
    |> Map.delete(:heartbeat)
    |> handle_packet(packet)
  end

  # 10 - Hello
  defp handle_packet(
         %{sup: sup, gateway: gateway} = state,
         %{
           op: 10,
           d: %{heartbeat_interval: heartbeat_interval}
         }
       ) do
    case state do
      %{seq: _seq, session: _session} ->
        state
        |> Command.resume()
        |> self_send(sup)

      _ ->
        state
        |> Command.identify()
        |> self_send(sup, gateway)
    end

    {:ok, ref} =
      :timer.send_interval(
        heartbeat_interval,
        :heartbeat
      )

    Map.put(state, :heartbeat, ref)
  end

  # 11 - Heartbeat ack
  defp handle_packet(%{shard_id: shard_id} = state, %{op: 11}) do
    Logger.debug("[Crux][Gateway][Shard #{shard_id}]: Received heartbeat ack")

    case state do
      %{heartbeat_timeout: ref} ->
        if ref do
          :timer.cancel(ref)
        end

        Map.delete(state, :heartbeat_timeout)

      _ ->
        state
    end
  end

  defp handle_packet(%{shard_id: shard_id} = state, packet) do
    Logger.warn(fn ->
      "[Crux][Gateway][Shard #{shard_id}]: Unhandled packet type" <>
        "#{packet.t || packet.d}: #{inspect(packet)}"
    end)

    state
  end
end
