defmodule Crux.Gateway.Connection do
  require Logger

  alias Crux.Gateway
  alias Crux.Gateway.Command
  alias Crux.Gateway.Gun

  alias :timer, as: Timer
  alias :gen_statem, as: GenStateM

  # These close codes are fatal because indicate there is something wrong that requires manual interaction.
  @fatal_close_codes [4004, 4010, 4011, 4012, 4013, 4014]

  # Timeouts and their messages
  @invalidated_wait 5_000 + 500

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
  @connecting :connecting
  @connected :connected

  @typep state :: %{
           # static
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

  def start_link(opts), do: GenStateM.start_link(__MODULE__, opts, [])

  def callback_mode(), do: [:state_functions, :state_enter]

  @spec init(map()) :: {:ok, :connecting, state()}
  def init(%{
        token: token,
        url: url,
        shard_id: shard_id,
        shard_count: shard_count,
        intents: intents,
        presence: presence
      }) do
    Logger.metadata(shard_id: shard_id, shard_count: shard_count)
    url = "#{url}/?v=8&encoding=etf&compress=zlib-stream"

    {:ok, conn} = Gun.start_link(url)

    data = %{
      token: token,
      shard_count: shard_count,
      shard_id: shard_id,
      intents: intents,
      presence: presence,
      conn: conn,
      heartbeat_ref: nil,
      heartbeat_timer: nil,
      session_id: nil,
      seq: nil,
      close_seq: nil
    }

    {:ok, @connecting, data}
  end

  #####
  # Disconnect
  ###
  # Cleans the heartbeat timer and reference up and then attempts to connect again.
  #####

  def disconnected(:enter, _old_state, %{heartbeat_timer: heartbeat_timer} = data) do
    if heartbeat_timer do
      {:ok, :cancel} = Timer.cancel(heartbeat_timer)
    end

    data = %{data | heartbeat_ref: nil, heartbeat_timer: nil}

    # Because, for some reason, you are not allowed to change state here
    action = {:timeout, 0, @connecting}

    {:keep_state, data, action}
  end

  # Hack to change the state in :enter
  def disconnected(:timeout, @connecting, data) do
    {:next_state, @connecting, data}
  end

  #####
  # Connecting
  ###
  # Connects to the gateway and waits for a hello before changing its state to connected.
  #####

  def connecting(:enter, _old_state, data) do
    Gun.reconnect(data.conn)

    :keep_state_and_data
  end

  def connecting(:state_timeout, :hello, %{conn: conn}) do
    # This will trigger a disconnect message, which will change the state to disconnected
    # No need to do that here then, keep things simple
    Gun.disconnect(conn, 4000, @hello_timeout_message)

    :keep_state_and_data
  end

  def connecting(:info, {:connected, conn}, %{conn: conn}) do
    # Automatically removed on state change, i.e. when receiving hello
    action = {:state_timeout, @hello_timeout, :hello}

    {:keep_state_and_data, action}
  end

  def connecting(:info, {:packet, conn, %{op: @hello, d: packet_data}}, %{conn: conn} = data) do
    %{
      heartbeat_interval: heartbeat_interval
    } = packet_data

    heartbeat_ref = {:heartbeat, Kernel.make_ref()}
    {:ok, heartbeat_timer} = Timer.send_interval(heartbeat_interval, heartbeat_ref)

    data = %{data | heartbeat_ref: heartbeat_ref, heartbeat_timer: heartbeat_timer}

    {:next_state, @connected, data}
  end

  # hello should be the first packet received, but just in case it's not.
  def connecting(:info, {:packet, conn, _other}, %{conn: conn}) do
    {:keep_state_and_data, :postpone}
  end

  def connecting(:info, {:disconnected, conn, {:close, code, message}}, %{conn: conn} = data) do
    Logger.warn(fn -> "Disconnected with #{code} and #{message}" end)

    {:next_state, @disconnected, data}
  end

  #####
  # Connected
  ###
  # We received the hello and are able to start working.
  ####

  def connected(:enter, _old_state, %{conn: conn} = data) do
    frame = Command.identify(data)
    :ok = Gun.send_frame(conn, frame)

    :keep_state_and_data
  end

  def connected(:state_timeout, :heartbeat, %{conn: conn}) do
    Logger.warn(fn ->
      """
      #{@heartbeat_timeout_message}
      Assuming zombie connection and will attempt to reconnect.
      """
    end)

    # This will trigger a disconnect message, which will change the state to disconnected
    # No need to do that here then, keep things simple
    Gun.disconnect(conn, 4000, @heartbeat_timeout_message)

    :keep_state_and_data
  end

  def connected(:info, ref, %{heartbeat_ref: ref} = data) do
    Logger.debug(fn -> "Sending scheduled heartbeat at sequence #{data.seq}." end)

    frame = Command.heartbeat(data.seq)
    :ok = Gun.send_frame(data.conn, frame)

    action = {:state_timeout, @heartbeat_timeout, :heartbeat}

    {:keep_state_and_data, action}
  end

  def connected(:info, {:heartbeat, other_ref}, %{heartbeat_ref: {:heartbeat, ref}}) do
    Logger.warn(fn ->
      "Received unexpected heartbeat message with the ref #{inspect(other_ref)},\
       expected ref to be #{inspect(ref)}"
    end)

    :keep_state_and_data
  end

  def connected(:info, {:disconnected, conn, {:close, code, message}}, %{conn: conn} = data) do
    Logger.warn(fn -> "Disconnected with #{code} and #{message}" end)

    if code in @fatal_close_codes do
      Logger.error(fn ->
        "Received a fatal close code #{code} (#{message}), this probably requires manual fixing!"
      end)

      {:stop, :fatal_close_code}
    else
      {:next_state, @disconnected, data}
    end
  end

  def connected(:info, {:packet, conn, packet}, %{conn: conn} = data) do
    data = update_seq(packet, data)

    case handle_packet(packet, data) do
      {data, action} ->
        {:keep_state, data, action}

      %{} = data ->
        {:keep_state, data}
    end
  end

  @spec handle_packet(map(), state) :: {state, GenStateM.action()} | state
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

    Process.sleep(@invalidated_wait)

    {frame, data} =
      if resumable? && seq && session_id do
        {Command.resume(data), data}
      else
        {Command.identify(data), %{data | seq: nil, session_id: nil}}
      end

    :ok = Gun.send_frame(conn, frame)

    data
  end

  defp handle_packet(%{op: @heartbeat_ack}, data) do
    Logger.debug(fn -> "Received OP #{@heartbeat_ack} (heartbeat_ack)." end)

    action = {:state_timeout, :cancel}
    {data, action}
  end

  defp handle_packet(%{op: @dispatch, t: type, d: packet_data}, data) do
    Logger.info(fn -> "Received a #{type} dispatch." end)

    # TODO: Dispatch type and packet_data to somewhere

    if type == "READY" do
      Logger.debug(fn -> "Received READY with session_id #{packet_data.session_id}." end)

      %{data | session_id: packet_data.session_id}
    else
      data
    end
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
