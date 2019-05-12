defmodule Crux.Gateway.IdentifyLimiter do
  # Handles the identify rate limit of 1 per 5 seconds.
  # https://discordapp.com/developers/docs/topics/gateway#identifying
  @moduledoc false

  alias Crux.Gateway

  use GenServer

  require Logger

  # 500 for sanity
  @timeout 5000 + 500

  @doc """
    Starts a `Crux.Gateway.IdentifyLimiter` process linked to the current process.
  """
  @spec start_link(args :: any()) :: GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @doc """
    Blocks the calling process until an identify may be sent.

    Automatically used by `Crux.Gateway.Connection`.
  """
  @spec queue(gateway :: Crux.Gateway.gateway()) :: :ok
  def queue(gateway) do
    gateway
    |> Gateway.get_limiter()
    |> GenServer.call(:queue, :infinity)
  end

  @doc false
  @spec init(term()) :: {:ok, term()}
  def init(_args) do
    Logger.debug("[Crux][Gateway][IdentifyLimiter]: Starting")

    # ratelimit reset
    state = 0

    {:ok, state}
  end

  @doc false
  @spec handle_call(term(), GenServer.from(), term()) :: term()
  def handle_call(:queue, _from, ratelimit_reset) do
    now = :os.system_time(:millisecond)

    if ratelimit_reset > now do
      :timer.sleep(ratelimit_reset - now)
    end

    Logger.debug("[Crux][Gateway][IdentifyLimiter]: Sending identify")

    {:reply, :ok, :os.system_time(:millisecond) + @timeout}
  end
end
