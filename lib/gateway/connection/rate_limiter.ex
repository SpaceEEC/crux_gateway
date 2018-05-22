defmodule Crux.Gateway.Connection.RateLimiter do
  @moduledoc """
    Handles [Rate Limiting](https://discordapp.com/developers/docs/topics/gateway#rate-limiting) for the gateway.

    This module is automatically used by `Crux.Gateway.Connection`, you do not need to worry about it.
  """

  use GenServer

  @registry Crux.Gateway.Registry

  @reset 60
  @limit 120

  @doc """
    Starts a rate limiter for a shard.

    This is automatically called when using `Crux.Gateway.start/1`.
  """
  @spec start_link(shard_id :: non_neg_integer) :: GenServer.on_start()
  def start_link(shard_id) do
    name = {:via, Registry, {@registry, {shard_id, :rate_limiter}}}

    GenServer.start_link(__MODULE__, shard_id, name: name)
  end

  @doc """
    Queues a packet.
    Blocks the calling process until the packet my be sent.

    The packets will return in the order as they arrive at the rate limiter, those are sent via `GenServer.call/2`.
    Returns the `packet` as is.

    Automatically invoked by using `Crux.Gateway.Connection.send_command/2`
  """
  @spec queue(packet :: term, shard_id :: non_neg_integer) :: term
  def queue(packet, shard_id) do
    with [{pid, _other}] when is_pid(pid) <-
           Registry.lookup(@registry, {shard_id, :rate_limiter}),
         true <- Process.alive?(pid) do
      GenServer.call(pid, {:queue, packet}, :infinity)
    else
      _ ->
        {:error, :not_found}
    end
  end

  @doc false
  def init(shard_id) do
    state = %{
      shard_id: shard_id,
      remaining: @limit,
      reset: 0
    }

    {:ok, state}
  end

  @doc false
  def handle_call(packet, from, %{remaining: 0, reset: reset} = state) do
    case reset - :os.system_time(:second) do
      reset when reset > 0 ->
        :timer.sleep(reset)

      _ ->
        nil
    end

    state =
      state
      |> Map.put(:reset, 0)
      |> Map.put(:remaining, @limit)

    handle_call(packet, from, state)
  end

  def handle_call(
        {:queue, packet},
        _from,
        %{remaining: remaining} = state
      ) do
    state = Map.put(state, :remaining, remaining - 1)

    state =
      if remaining == @limit,
        do: Map.put(state, :reset, :os.system_time(:second) + @reset),
        else: state

    {:reply, packet, state}
  end
end
