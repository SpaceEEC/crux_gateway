defmodule Crux.Gateway.Connection.Gun do
  @moduledoc false

  # Wrapper module for `:gun`, making it easier to swap out the WebSocket clients if necessary in the future.

  # Sends messages to the invoking process:
  # - `{:connected, pid}`
  # - `{:disconnected, pid, {:close, code, message}}`
  # - `{:packet, pid, packet}`

  alias :erlang, as: Erlang
  alias :gen_statem, as: GenStateM
  alias :gun, as: Gun
  alias :http_uri, as: HttpUri
  alias :zlib, as: Zlib

  alias Crux.Gateway.Util

  require Logger

  @max_size 4096

  ### Client API

  @doc """
  Starts a gun process linked to the current process.
  """
  def start_link(uri) do
    GenStateM.start_link(__MODULE__, {uri, self()}, [])
  end

  @doc """
  Instructs the gun process to reconnect to the initially provided url.
  """
  def reconnect(conn) do
    GenStateM.call(conn, :reconnect)
  end

  @doc """
  Instructs the gun process to disconnect. The process will not reconnect on its own.
  """
  def disconnect(conn, code, message) do
    GenStateM.call(conn, {:disconnect, code, message})
  end

  @doc """
  Instructs the gun process to disconnect and stop.
  """
  def stop(conn, code, message) do
    GenStateM.call(conn, {:stop, code, message})
  end

  @doc """
  Instructs the gun process to send a frame.
  """
  def send_frame(conn, frame)

  def send_frame(_conn, {:binary, binary})
      when byte_size(binary) > @max_size do
    {:error, :too_large}
  end

  def send_frame(conn, frame) do
    GenStateM.call(conn, {:send, frame})
  end

  # Messages going from the server back to the client.
  defp send_disconnected(%{parent: parent}, code, message) do
    Kernel.send(parent, {:disconnected, self(), {:close, code, message}})
  end

  defp send_connected(%{parent: parent}) do
    Kernel.send(parent, {:connected, self()})
  end

  defp send_packet(%{parent: parent}, packet) do
    Kernel.send(parent, {:packet, self(), packet})
  end

  ### Server API

  # States
  @disconnected :disconnected
  @connecting :connecting
  @connected :connected

  @attempt_limit 5

  defstruct [
    :parent,
    :host,
    :port,
    :path,
    :query,
    :zlib,
    :buffer,
    :conn,
    :attempts,
    :expect_disconnect
  ]

  @typep t :: %__MODULE__{
           # The spawning process
           parent: pid(),
           # Where to connect to
           host: charlist(),
           port: pos_integer(),
           path: String.t(),
           query: String.t(),
           # zlib stream context and its buffer
           zlib: Zlib.zstream() | nil,
           buffer: binary(),
           # WS connection wrapper process
           conn: pid() | nil,
           # Limit the amount of attempts to establish a connection
           attempts: non_neg_integer(),
           # Whether we are expecting a gun_down / disconnect
           # and do not want to notify the spawning process again
           expect_disconnect: boolean()
         }

  @behaviour GenStateM

  def callback_mode(), do: [:state_functions, :state_enter]

  @spec init({String.t(), pid()}) :: {:ok, :connecting, t()} | {:stop, :bad_uri}
  def init({uri, parent}) do
    case HttpUri.parse(uri, [{:scheme_defaults, [{:wss, 443}]}]) do
      {:error, term} ->
        Logger.error(fn -> "Failed to parse uri #{inspect(uri)}, reason #{inspect(term)}." end)

        {:stop, :bad_uri}

      {:ok, {:wss, "", host, port, path, query}} ->
        data = %__MODULE__{
          parent: parent,
          host: String.to_charlist(host),
          port: port,
          path: path,
          query: query,
          zlib: nil,
          buffer: <<>>,
          conn: nil,
          attempts: 0,
          expect_disconnect: false
        }

        {:ok, @disconnected, data}
    end
  end

  # From init
  def disconnected(:enter, @disconnected, _data) do
    :keep_state_and_data
  end

  def disconnected(:enter, _old_state, data) do
    try do
      Zlib.inflateEnd(data.zlib)
    rescue
      _ -> nil
    end

    :ok = Zlib.close(data.zlib)

    :ok = Gun.close(data.conn)

    data = %{data | conn: nil, zlib: nil}

    {:keep_state, data}
  end

  def disconnected({:call, from}, :reconnect, data) do
    {:next_state, @connecting, data, {:reply, from, :ok}}
  end

  def disconnected({:call, from}, {:disconnect, _code, _message}, _data) do
    {:keep_state_and_data, {:reply, from, :ok}}
  end

  def disconnected({:call, from}, {:stop, _code, _message}, _data) do
    {:stop_and_reply, :normal, {:reply, from, :ok}}
  end

  def disconnected({:call, from}, {:send, _frame}, _data) do
    {:keep_state_and_data, {:reply, from, {:error, :disconnected}}}
  end

  def connecting(:enter, _old_state, data) do
    z = Zlib.open()
    Zlib.inflateInit(z)

    attempts = data.attempts + 1
    data = %{data | attempts: attempts}

    Logger.debug(fn ->
      "Starting a process to connect to #{data.host}:#{data.port} (Attempt: #{attempts} / #{@attempt_limit})"
    end)

    # > Gun does not currently support Websocket over HTTP/2.
    {:ok, conn} = Gun.open(data.host, data.port, %{protocols: [:http]})

    Logger.debug(fn -> "Process started, waiting for its connection to be up." end)

    conn
    |> Gun.await_up()
    |> case do
      {:ok, :http} ->
        Logger.debug(fn ->
          "Connection is up, now upgrading it to use the WebSocket protocol, using " <>
            data.path <> data.query
        end)

        stream_ref = Gun.ws_upgrade(conn, data.path <> data.query)
        :ok = await_upgrade(conn, stream_ref)

        Logger.debug(fn ->
          "Connection upgraded to use the WebSocket protocol, we are good to go!"
        end)

        send_connected(data)

        data = %{data | conn: conn, zlib: z, attempts: 0}

        {:keep_state, data, {:timeout, 0, :connected}}

      {:error, :timeout} when attempts >= @attempt_limit ->
        Logger.error(fn ->
          "Connection timed out, no attempts remaining, won't retry. (#{attempts} / #{@attempt_limit})"
        end)

        {:stop, :connection_failure, data}

      {:error, :timeout} ->
        Logger.warn(fn ->
          "Connection timed out, will retry. (#{attempts} / #{@attempt_limit})"
        end)

        {:repeat_state, data}
    end
  end

  def connecting(:timeout, :connected, data) do
    {:next_state, @connected, data}
  end

  # The connecting state can not receive any messages due to its blocking nature.

  def connected(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def connected(
        :info,
        {:gun_down, conn, _protocol, reason, _killed_stream, _uprocessed_stream},
        %{conn: conn, expect_disconnect: expect_disconnect} = data
      ) do
    if expect_disconnect do
      {code, message} = expect_disconnect

      send_disconnected(data, code, message)
    else
      Logger.warn(fn -> "Unexpected gun_down! Connection down! Reason: #{inspect(reason)}" end)

      send_disconnected(data, :unknown, "gun_down")
    end

    data = %{data | expect_disconnect: false}

    {:next_state, @disconnected, data}
  end

  def connected(:info, {:gun_error, conn, reason}, %{conn: conn}) do
    Logger.warn(fn -> "Connection error: #{inspect(reason)}" end)

    :keep_state_and_data
  end

  def connected(:info, {:gun_error, conn, _stream_ref, reason}, %{conn: conn}) do
    Logger.warn(fn -> "Stream error: #{inspect(reason)}" end)

    :keep_state_and_data
  end

  def connected(:info, {:gun_ws, conn, _stream_ref, {:binary, frame}}, %{conn: conn} = data) do
    frame_size = byte_size(frame) - 4
    <<_data::binary-size(frame_size), suffix::binary>> = frame

    buffer = data.buffer <> frame

    new_buffer =
      if suffix == <<0x00, 0x00, 0xFF, 0xFF>> do
        packet =
          data.zlib
          |> Zlib.inflate(buffer)
          |> Erlang.iolist_to_binary()
          |> Erlang.binary_to_term()
          |> Util.atomify()

        send_packet(data, packet)

        <<>>
      else
        buffer
      end

    data = %{data | buffer: new_buffer}

    {:keep_state, data}
  end

  def connected(:info, {:gun_ws, conn, _stream_ref, {:text, data}}, %{conn: conn} = data) do
    Logger.warn(fn -> "Received unexpected text frame: #{inspect(data)}" end)

    :keep_state_and_data
  end

  def connected(:info, {:gun_ws, conn, _stream_ref, frame}, %{conn: conn} = data) do
    data =
      case maybe_close(frame) do
        {:close, code, message} ->
          Logger.warn(fn -> "Disconnected with code #{code} and message #{message}" end)

          %{data | expect_disconnect: {code, message}}

        :error ->
          Logger.warn(fn -> "Received an unexpected frame: #{frame}" end)

          data
      end

    {:keep_state, data}
  end

  def connected({:call, from}, :reconnect, _data) do
    {:keep_state_and_data, {:reply, from, :ok}}
  end

  def connected({:call, from}, {:disconnect, code, message}, data) do
    :ok = Gun.ws_send(data.conn, {:close, code, message})

    data = %{data | expect_disconnect: {code, message}}

    {:keep_state, data, {:reply, from, :ok}}
  end

  def connected({:call, from}, {:stop, code, message}, data) do
    :ok = Gun.ws_send(data.conn, {:close, code, message})

    :ok = Gun.close(data.conn)

    send_disconnected(data, code, message)

    {:stop_and_reply, :normal, {:reply, from, :ok}}
  end

  def connected({:call, from}, {:send, frame}, data) do
    :ok = Gun.ws_send(data.conn, frame)

    {:keep_state_and_data, {:reply, from, :ok}}
  end

  # Handle all possible close frame options
  defp maybe_close(:close), do: {:close, :unknown, "No message received."}
  defp maybe_close({:close, message}), do: {:close, :unknown, message}
  defp maybe_close({:close, close_code, message}), do: {:close, close_code, message}
  defp maybe_close(_frame), do: :error

  # Since gun does not implement one itself for some reason?
  defp await_upgrade(conn, stream_ref) do
    receive do
      {:gun_upgrade, ^conn, ^stream_ref, _protocols, _headers} ->
        :ok

      {:gun_response, ^conn, ^stream_ref, _is_fin, status, headers} ->
        {:error, status, headers}

      {:gun_error, ^conn, ^stream_ref, reason} ->
        {:error, reason}

      {:gun_error, ^conn, reason} ->
        {:error, reason}
    after
      5000 ->
        {:error, :timeout}
    end
  end
end
