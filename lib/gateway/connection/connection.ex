defmodule Crux.Gateway.Connection do
  @moduledoc """
    Module handling the actual connection (shard) to Discord.
  """
  alias Crux.Gateway
  alias Crux.Gateway.{Command, Connection, IdentifyLimiter, Util}
  alias Crux.Gateway.Connection.{Producer, RateLimiter}

  use WebSockex

  require Logger

  @resume_timeout 5_000 + 500

  @hello_timeout 20_000
  @hello_timeout_message "Did not receive hello after 20 seconds"

  @heartbeat_timeout 20_000
  @heartbeat_timeout_message "Did not receive heartbeat ack after 20 seconds"

  @typep state :: %{
           # static
           required(:token) => String.t(),
           required(:url) => String.t(),
           required(:shard_count) => pos_integer(),
           required(:shard_id) => non_neg_integer(),
           required(:presence) => Gateway.presence(),
           required(:gateway) => pid(),
           required(:sup) => pid(),
           # per session
           optional(:session) => String.t(),
           optional(:seq) => non_neg_integer(),
           optional(:zlib) => :zlib.zstream(),
           optional(:hello_timeout) => :timer.tref(),
           optional(:heartbeat) => :timer.tref(),
           optional(:heartbeat_timeout) => :timer.tref(),
           optional(:close_seq) => non_neg_integer()
         }

  @doc false
  @spec start_link(args :: map()) :: {:ok, pid} | {:error, term}
  def start_link(%{url: url, shard_id: shard_id, shard_count: shard_count} = args) do
    url = "#{url}/?encoding=etf&v=6&compress=zlib-stream"

    Logger.metadata(shard_id: shard_id, shard_count: shard_count)

    Logger.info(fn -> "Booting, connecting to #{url}" end)

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
  @spec handle_connect(term(), term()) :: {:ok, state()}
  def handle_connect(con, [args]) do
    Logger.info(fn -> "Connected" end)

    handle_connect(con, args)
  end

  def handle_connect(con, %{zlib: {_, z}} = state) do
    Logger.info(fn -> "Reconnected" end)

    try do
      :zlib.inflateEnd(z)
    rescue
      _ -> nil
    end

    :zlib.close(z)

    state = Map.delete(state, :zlib)

    handle_connect(con, state)
  end

  def handle_connect(_, state) do
    {:ok, ref} = :timer.send_after(@hello_timeout, :hello_timeout)

    z = :zlib.open()
    :zlib.inflateInit(z)

    state =
      state
      |> Map.put(:zlib, {<<>>, z})
      |> Map.put(:hello_timeout, ref)

    {:ok, state}
  end

  @spec handle_disconnect(map(), state()) :: {:reconnect, state()}
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

  def handle_disconnect(%{reason: {:remote, code, reason}}, state) do
    Logger.warn(fn ->
      "Disconnected: #{code} - \"#{reason}\""
    end)

    seq = Map.get(state, :seq, 0)
    state = Map.put(state, :close_seq, seq)

    {:reconnect, state}
  end

  def handle_disconnect(
        %{reason: {:local, 4000, message}},
        state
      )
      when message in [
             @heartbeat_timeout_message,
             @hello_timeout_message
           ] do
    Logger.warn(fn ->
      "Disconnected: #{message}. Waiting five seconds before reconnecting"
    end)

    seq = Map.get(state, :seq, 0)
    state = Map.put(state, :close_seq, seq)

    :timer.sleep(5_000)

    {:reconnect, state}
  end

  def handle_disconnect(reason, state) do
    reason = Map.get(reason, :reason, reason)

    Logger.warn(fn ->
      "Disconnected: #{inspect(reason)}. Waiting five seconds before reconnecting"
    end)

    state = Map.put(state, :close_seq, Map.get(state, :seq, 0))

    :timer.sleep(5_000)

    {:reconnect, state}
  end

  @doc false
  @spec handle_info(term(), state()) ::
          {:close, WebSockex.close_frame(), state()}
          | {:reply, WebSockex.frame(), state()}
          | {:ok, state()}
  def handle_info(:stop, state), do: {:close, {1000, "Closing connection"}, state}
  def handle_info({:send, frame}, state), do: {:reply, frame, state}

  def handle_info(:heartbeat, %{sup: sup} = state) do
    Logger.debug(fn ->
      "Sending heartbeat at seq #{Map.get(state, :seq, "nil")}"
    end)

    command =
      state
      |> Map.get(:seq, nil)
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

  def handle_info(other, state) do
    Logger.warn(fn ->
      "Received unexpected message: #{inspect(other)}"
    end)

    {:ok, state}
  end

  @doc false
  @spec terminate(term(), term()) :: nil
  def terminate(reason, _state) do
    Logger.warn(fn ->
      "Terminating due to #{inspect(reason)}"
    end)

    nil
  end

  @doc false
  @spec handle_frame(term(), state()) :: {:ok, state()}
  def handle_frame({:binary, frame}, %{zlib: {buffer, z}} = state) do
    frame_size = byte_size(frame) - 4
    <<_data::binary-size(frame_size), suffix::binary>> = frame

    buffer = buffer <> frame

    {new_buffer, packet} =
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

    state = %{state | zlib: {new_buffer, z}}

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

  @spec handle_packet(state(), map()) :: state()
  defp handle_packet(
         %{sup: sup, shard_id: shard_id} = state,
         %{
           t: :READY,
           d: %{
             session_id: session_id
           }
         } = packet
       ) do
    Logger.info(fn ->
      "Ready"
    end)

    Producer.dispatch(sup, packet, shard_id)

    state
    |> Map.delete(:close_seq)
    |> Map.put(:session, session_id)
  end

  defp handle_packet(%{sup: sup, shard_id: shard_id} = state, %{t: :RESUMED} = packet) do
    {close_seq, state} = Map.pop(state, :close_seq, 0)

    Logger.info(fn ->
      "Resumed #{close_seq} -> #{Map.get(state, :seq)}"
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
  defp handle_packet(
         %{sup: sup, seq: seq, session: session, token: token} = state,
         %{
           op: 9,
           d: true
         }
       )
       when is_binary(token) and is_binary(session) and is_integer(seq) and seq > 0 do
    Logger.warn(fn ->
      "Invalid session, will try to resume"
    end)

    :timer.sleep(@resume_timeout)

    command = Command.resume(state)

    self_send(command, sup)

    state
  end

  # 9 - Invalid Session - New
  defp handle_packet(%{gateway: gateway, sup: sup} = state, %{op: 9}) do
    Logger.warn(fn ->
      "Invalid session, will identify as a new one"
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
  defp handle_packet(state, %{op: 11}) do
    Logger.debug(fn -> "Received heartbeat ack" end)

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

  defp handle_packet(state, packet) do
    Logger.warn(fn ->
      "Unhandled packet type" <>
        "#{packet.t || packet.d}: #{inspect(packet)}"
    end)

    state
  end
end
