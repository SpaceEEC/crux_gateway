defmodule Crux.Gateway.IdentifyLimiter do
  @moduledoc """
    Handles the [Identifying](https://discordapp.com/developers/docs/topics/gateway#identifying) rate limit of 1 per 5 seconds.

    This module is automatically used by `Crux.Gateway.Connection`, you do not need to worry about it.
  """

  use GenServer

  require Logger

  @timeout 5500
  # + 500 for sanity

  @doc """
    Starts the identify limiter.
  """
  def start_link(_args), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
    Starts the module if necessary and queues the packet.
    Blocks the process until the identify may be sent.

    The packets will return in the order as they arrive at the rate limiter, those are sent via `GenServer.call/2`.
    Returns the `packet` as is.

    Automatically used by `Crux.Gateway.Connection`.
  """
  @spec queue(packet :: term) :: term
  def queue(packet) do
    case GenServer.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(pid, {:queue, packet}, :infinity)

      _ ->
        Supervisor.start_child(
          Crux.Gateway.Supervisor,
          Supervisor.child_spec(
            __MODULE__,
            id: __MODULE__,
            restart: :temporary
          )
        )

        queue(packet)
    end
  end

  @doc false
  def init(:ok) do
    Logger.debug("[Crux][Gateway][IdentifyLimiter]: Start")

    {:ok, {nil, 0}}
  end

  @doc false
  def handle_info(:stop, state) do
    Logger.debug("[Crux][Gateway][IdentifyLimiter]: Stopping")

    {:stop, :normal, state}
  end

  @doc false
  def handle_call({:queue, packet}, _from, {nil, reset}) do
    if reset > :os.system_time(:milli_seconds) do
      :timer.sleep(reset - :os.system_time(:milli_seconds))
    end

    Logger.debug("[Crux][Gateway][IdentifyLimiter]: Sending identify")
    {:ok, ref} = :timer.send_after(@timeout, :stop)

    {:reply, packet, {:os.system_time(:milli_seconds) + @timeout, ref}}
  end

  def handle_call({:queue, _packet} = message, from, {timer, reset}) do
    :timer.cancel(timer)

    handle_call(message, from, {nil, reset})
  end
end
