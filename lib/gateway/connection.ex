defmodule Crux.Gateway.Connection do
  @moduledoc false

  # https://discord.com/developers/docs/topics/gateway
  require Logger

  alias Crux.Gateway
  alias Crux.Gateway.Command
  alias Crux.Gateway.Connection.Gun
  alias Crux.Gateway.RateLimiter
  alias Crux.Gateway.Registry
  alias Crux.Gateway.Shard.Producer

  alias :rand, as: Rand
  alias :timer, as: Timer
  alias :gen_statem, as: GenStateM

  # These close codes are fatal because they indicate that
  # there is something wrong that requires manual interaction.
  @authentication_failed 4004
  @invalid_shard 4010
  @sharding_required 4011
  @invalid_api_version 4012
  @invalid_intents 4013
  @disallowed_intents 4014
  @fatal_close_codes [
    @authentication_failed,
    @invalid_shard,
    @sharding_required,
    @invalid_api_version,
    @invalid_intents,
    @disallowed_intents
  ]

  # Timeouts and their messages
  @hello_timeout 40_000
  @hello_timeout_message "Did not receive hello after 40 seconds"

  @heartbeat_timeout 20_000
  @heartbeat_timeout_message "Did not receive heartbeat ack after 20 seconds"

  # Relevant OPs we care about here
  @dispatch 0
  @heartbeat 1
  @reconnect 7
  @invalid_session 9
  @hello 10
  @heartbeat_ack 11

  # GenSateM states for this module
  @disconnected :disconnected
  @waiting_hello :waiting_hello
  @waiting_ready :waiting_ready
  @ready :ready

  def send_command(name, {shard_id, shard_count}, packet) do
    name
    |> Registry.name()
    |> Registry.lookup_connection(shard_id, shard_count)
    |> case do
      :error ->
        {:error, :not_found}

      pid ->
        with :ok <- RateLimiter.enqueue_command(name, shard_id, shard_count) do
          GenStateM.call(pid, {:send, packet})
        end
    end
  end

  defstruct [
    :name,
    :token,
    :shard_count,
    :shard_id,
    :intents,
    :presence,
    :conn,
    :heartbeat_ref,
    :heartbeat_timer,
    :session_id,
    :seq,
    :close_seq
  ]

  @typep t :: %__MODULE__{
           # static
           name: atom(),
           token: String.t(),
           shard_count: non_neg_integer(),
           shard_id: non_neg_integer(),
           intents: non_neg_integer(),
           presence: Gateway.presence() | nil,
           conn: Gun.conn(),
           # per session
           heartbeat_ref: reference() | nil,
           heartbeat_timer: Timer.tref() | nil,
           session_id: String.t() | nil,
           seq: non_neg_integer() | nil,
           close_seq: non_neg_integer() | nil
         }

  @behaviour GenStateM

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  def callback_mode(), do: [:handle_event_function, :state_enter]

  def start_link(
        %{
          name: name,
          shard_id: shard_id,
          shard_count: shard_count
        } = opts
      ) do
    Logger.info(fn -> "Starting connection {#{shard_id}, #{shard_count}}." end)

    name =
      name
      |> Registry.name()
      |> Registry.via_connection(shard_id, shard_count)

    GenStateM.start_link(name, __MODULE__, opts, [])
  end

  @spec init(map()) :: {:ok, :waiting_hello, t()}
  def init(
        %{
          name: name,
          token: token,
          url: url,
          shard_id: shard_id,
          shard_count: shard_count,
          intents: intents
        } = data
      ) do
    Logger.metadata(shard_id: shard_id, shard_count: shard_count, intents: intents)

    # In order to gracefully shutdown
    Process.flag(:trap_exit, true)

    url = "#{url}/?v=9&encoding=etf&compress=zlib-stream"

    {:ok, conn} = Gun.start_link(url)

    data = %__MODULE__{
      name: name,
      token: token,
      shard_count: shard_count,
      shard_id: shard_id,
      intents: intents,
      presence: data[:presence],
      conn: conn,
      heartbeat_ref: nil,
      heartbeat_timer: nil,
      session_id: data[:session_id],
      seq: data[:seq],
      close_seq: data[:seq]
    }

    {:ok, @waiting_hello, data}
  end

  #####
  # handle_event
  ###
  # Workaround to get access to __STACKTRACE__
  ####

  # https://erlang.org/doc/man/gen_statem.html#type-state_enter_result
  # https://erlang.org/doc/man/gen_statem.html#type-event_handler_result
  def handle_event(type, content, state, data) do
    apply(__MODULE__, state, [type, content, data])
  rescue
    exception ->
      stacktrace = __STACKTRACE__

      Logger.error(fn ->
        """
        #{Exception.format(:error, exception, stacktrace)}

        Additional data:
        type: #{inspect(type)}
        content: #{inspect(content)}
        state: #{inspect(state)}
        data: #{inspect(data)}\
        """
      end)

      reraise exception, stacktrace
  end

  #####
  # disconnected
  ###
  # Disconnected, if possible, reconnect, otherwise stop.
  #####

  def disconnected(:enter, _old_state, %{heartbeat_timer: heartbeat_timer} = data) do
    # Stop heartbeating
    if heartbeat_timer do
      {:ok, :cancel} = Timer.cancel(heartbeat_timer)
    end

    Logger.debug(fn -> "Connection closed at seq: #{data.seq} " end)
    data = %{data | heartbeat_ref: nil, heartbeat_timer: nil, close_seq: data.seq}

    # Stop an eventual heartbeat timeout
    action = {{:timeout, :heartbeat}, :cancel}

    {:keep_state, data, action}
  end

  def disconnected(:info, {:disconnected, conn, {:close, code, message}}, %{conn: conn} = data) do
    if code in @fatal_close_codes do
      Logger.error(fn ->
        "Received a fatal close frame #{code} (#{message}), this probably requires manual fixing!"
      end)

      if code == @invalid_api_version do
        Logger.error(fn -> "This sounds like there is something wrong with crux_gateway." end)
      end

      {:stop, :fatal_close_code}
    else
      Logger.warn(fn ->
        "Received a close frame #{code} (#{message}), will reconnect."
      end)

      {:next_state, @waiting_hello, data}
    end
  end

  def disconnected(:info, {:packet, conn, _packet}, %{conn: conn}) do
    {:keep_state_and_data, :postpone}
  end

  def disconnected({:call, from}, {:send, _frame}, _data) do
    {:keep_state_and_data, {:reply, from, {:error, :not_ready}}}
  end

  #####
  # waiting_hello
  ###
  # Connect to the gateway and wait for the hello packet.
  #####

  def waiting_hello(:enter, _old_state, %{conn: conn}) do
    Gun.reconnect(conn)

    :keep_state_and_data
  end

  def waiting_hello(:state_timeout, :hello, %{conn: conn}) do
    Logger.warn(fn -> "Timed out waiting for hello, disconnecting..." end)

    # This will trigger a disconnect message, which will change the state to disconnected
    # No need to do that here then, keep things simple
    Gun.disconnect(conn, 4000, @hello_timeout_message)

    :keep_state_and_data
  end

  def waiting_hello(:info, {:connected, conn}, %{conn: conn}) do
    action = {:state_timeout, @hello_timeout, :hello}

    {:keep_state_and_data, action}
  end

  def waiting_hello(:info, {:packet, conn, %{op: @hello, d: packet_data}}, %{conn: conn} = data) do
    %{
      heartbeat_interval: heartbeat_interval
    } = packet_data

    Logger.debug(fn ->
      "Received OP #{@hello} (HELLO) with heartbeat_interval #{heartbeat_interval}"
    end)

    heartbeat_ref = {:heartbeat, Kernel.make_ref()}
    {:ok, heartbeat_timer} = Timer.send_interval(heartbeat_interval, heartbeat_ref)

    data = %{data | heartbeat_ref: heartbeat_ref, heartbeat_timer: heartbeat_timer}

    {:next_state, @waiting_ready, data}
  end

  def waiting_hello(type, message, data), do: handle_common(:waiting_hello, type, message, data)

  #####
  # waiting_ready
  ###
  # Send an identfiy or resume and wait for the ready or resumed packet.
  #####

  def waiting_ready(:enter, _old_state, %{conn: conn} = data) do
    if data.seq && data.session_id do
      Logger.debug(fn -> "Sending RESUME" end)

      frame = Command.resume(data)
      :ok = Gun.send_frame(conn, frame)
    else
      # To avoid blocking the connection for a longer time (and thus miss heartbeats).
      Kernel.spawn(fn ->
        Logger.debug(fn -> "Queueing IDENTIFY" end)
        :ok = RateLimiter.enqueue_identify(data)
        Logger.debug(fn -> "Sending IDENTIFY" end)

        frame = Command.identify(data)
        :ok = Gun.send_frame(conn, frame)
      end)
    end

    :keep_state_and_data
  end

  def waiting_ready(
        :info,
        {:packet, conn, %{op: @dispatch, t: type, d: packet_data} = packet},
        %{conn: conn} = data
      )
      when type in [:READY, :RESUMED] do
    data = update_seq(packet, data)

    data =
      case type do
        :READY ->
          Logger.debug(fn -> "Received a READY with session_id #{packet_data.session_id}" end)
          %{data | session_id: packet_data.session_id}

        :RESUMED ->
          Logger.debug(fn ->
            """
            Successfully resumed the connection at seq #{data.seq}.
            Replayed events: #{data.seq - data.close_seq - 1}
            """
          end)

          %{data | close_seq: nil}
      end

    {:next_state, @ready, data, :postpone}
  end

  def waiting_ready(type, message, data), do: handle_common(:waiting_ready, type, message, data)

  #####
  # ready
  ###
  # Ready to receive events and send commands.
  #####

  def ready(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def ready(
        :info,
        {:packet, conn, %{t: type, op: @dispatch} = packet},
        %{conn: conn} = data
      ) do
    data = update_seq(packet, data)

    Logger.info(fn -> "Received a #{type} dispatch." end)

    Producer.dispatch(data, {packet.t, packet.d, {data.shard_id, data.shard_count}})

    {:keep_state, data}
  end

  def ready(type, message, data) do
    handle_common(:ready, type, message, data)
  end

  def terminate(:shutdown, state, data) do
    Logger.info(fn ->
      "Shutting down connection {#{data.shard_id}, #{data.shard_count}} in state #{inspect(state)}."
    end)

    if data.conn do
      Gun.disconnect(data.conn, 1000, "Shutting down.")
    end
  end

  def terminate(:fatal_close_code, _state, data) do
    Gateway.stop_shard(data.name, {data.shard_id, data.shard_count})
  end

  def terminate(reason, state, data) do
    Logger.error(fn ->
      "#{inspect(reason)} #{inspect(state)} #{inspect(data)}"
    end)

    Gateway.stop_shard(data.name, {data.shard_id, data.shard_count})
  end

  defp handle_common(state, type, message, data)

  defp handle_common(:ready, {:call, from}, {:send, frame}, %{conn: conn}) do
    response = Gun.send_frame(conn, frame)
    {:keep_state_and_data, {:reply, from, response}}
  end

  defp handle_common(_state, {:call, from}, {:send, _frame}, _data) do
    {:keep_state_and_data, {:reply, from, {:error, :not_ready}}}
  end

  defp handle_common(_state, {:timeout, :heartbeat}, :heartbeat, %{conn: conn}) do
    Logger.warn(fn ->
      """
      #{@heartbeat_timeout_message}
      Assuming zombie connection, reconnecting...
      """
    end)

    # This will trigger a disconnect message, which will change the state to disconnected
    # No need to do that here then, keep things simple
    Gun.disconnect(conn, 4000, @heartbeat_timeout_message)

    :keep_state_and_data
  end

  defp handle_common(_state, :info, ref, %{heartbeat_ref: ref} = data) do
    Logger.debug(fn -> "Sending scheduled heartbeat at sequence #{data.seq}." end)

    frame = Command.heartbeat(data.seq)

    case Gun.send_frame(data.conn, frame) do
      :ok -> :ok
      {:error, term} -> Logger.error(fn -> "Failed to send heartbeat #{term}" end)
    end

    action = {{:timeout, :heartbeat}, @heartbeat_timeout, :heartbeat}

    {:keep_state_and_data, action}
  end

  defp handle_common(_state, :info, {:heartbeat, other_ref}, %{heartbeat_ref: {:heartbeat, ref}}) do
    Logger.warn(fn ->
      "Received unexpected heartbeat message with the ref #{inspect(other_ref)},\
       expected ref to be #{inspect(ref)}"
    end)

    :keep_state_and_data
  end

  defp handle_common(_state, :info, {:packet, conn, %{op: op} = packet}, %{conn: conn} = data)
       when op != @dispatch do
    data = update_seq(packet, data)

    case handle_packet(packet, data) do
      {data, action} ->
        {:keep_state, data, action}

      %{} = data ->
        {:keep_state, data}
    end
  end

  # Postpone all unhandled dispatch packets before ready
  defp handle_common(state, :info, {:packet, conn, packet}, %{conn: conn} = data)
       when state != :ready do
    data = update_seq(packet, data)

    {:keep_state, data, :postpone}
  end

  defp handle_common(_state, :info, {:disconnected, conn, _close_frame}, %{conn: conn} = data) do
    {:next_state, @disconnected, data, :postpone}
  end

  defp handle_packet(packet, data)

  defp handle_packet(%{op: @heartbeat}, %{conn: conn, seq: seq} = data) do
    Logger.debug(fn -> "Received OP #{@heartbeat} (heartbeat) at sequence #{seq}." end)

    frame = Command.heartbeat(seq)
    :ok = Gun.send_frame(conn, frame)

    data
  end

  defp handle_packet(%{op: @reconnect}, %{conn: conn} = data) do
    message = "Received OP #{@reconnect} (reconnect)."
    Logger.warn(fn -> message end)

    # This will trigger a disconnect message, which will change the state to disconnected
    # No need to do that here then, keep things simple
    Gun.disconnect(conn, 4000, message)

    data
  end

  defp handle_packet(
         %{op: @invalid_session, d: resumable?},
         %{conn: conn, seq: seq, session_id: session_id} = data
       ) do
    Logger.warn(fn ->
      """
      Received OP #{@invalid_session} (invalid session).
      resumable?: #{resumable?} seq: #{seq} session_id: #{session_id}
      """
    end)

    data =
      if resumable? && seq && session_id do
        Logger.debug(fn -> "Sending RESUME" end)
        frame = Command.resume(data)

        :ok = Gun.send_frame(conn, frame)

        data
      else
        # To avoid blocking the connection for a longer time (and thus miss heartbeats).
        Kernel.spawn(fn ->
          # "wait a random amount of time—between 1 and 5 seconds"
          sleep_time = 1_000 + Rand.uniform(4000)
          Logger.debug(fn -> "Waiting #{sleep_time} before identifying." end)
          Process.sleep(sleep_time)

          Logger.debug(fn -> "Queueing IDENTIFY" end)
          :ok = RateLimiter.enqueue_identify(data)
          Logger.debug(fn -> "Sending IDENTIFY" end)

          frame = Command.identify(data)
          :ok = Gun.send_frame(conn, frame)
        end)

        %{data | seq: nil, session_id: nil}
      end

    data
  end

  defp handle_packet(%{op: @heartbeat_ack}, data) do
    Logger.debug(fn -> "Received OP #{@heartbeat_ack} (heartbeat_ack)." end)

    action = {{:timeout, :heartbeat}, :cancel}
    {data, action}
  end

  defp handle_packet(%{op: op} = packet, data) do
    Logger.warn(fn -> "Received unexpected OP #{op} packet: #{inspect(packet)}" end)

    data
  end

  ###
  # Helpers
  ###

  defp update_seq(packet, data)

  defp update_seq(%{s: s}, %{seq: seq} = data)
       # No sequence received before
       when is_nil(seq)
       # Received a new sequence and it's higher than our current sequence
       when is_number(s) and s > seq do
    %{data | seq: s}
  end

  # Either received no sequence or it's lower than our current sequence
  defp update_seq(_packet, data), do: data
end
