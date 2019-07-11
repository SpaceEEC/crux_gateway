defmodule Crux.Gateway.Connection.RateLimiter do
  # Handles rate limiting for a gateway.
  # https://discordapp.com/developers/docs/topics/gateway#rate-limiting
  @moduledoc false

  alias Crux.Gateway.Connection

  use GenServer

  @reset 60
  @limit 120

  @typep state :: %{
           remaining: non_neg_integer(),
           reset: non_neg_integer()
         }

  @doc """
    Starts a `Crux.Gateway.Connection.RateLimiter` process linked to the current process.
  """
  @spec start_link(args :: any()) :: GenServer.on_start()
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @doc """
    Blocks the calling process until a command may be sent.
  """
  @spec queue(sup :: GenServer.server()) :: :ok
  def queue(sup) do
    sup
    |> Connection.Supervisor.get_rate_limiter()
    |> GenServer.call(:queue, :infinity)
  end

  @doc false
  @spec init(term()) :: {:ok, state()}
  def init(_args) do
    state = %{
      remaining: @limit,
      reset: 0
    }

    {:ok, state}
  end

  @doc false
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, :ok, state()}
  def handle_call(:queue, from, %{remaining: 0, reset: reset} = state) do
    case reset - :os.system_time(:seconds) do
      reset when reset > 0 ->
        :timer.sleep(reset)

      _ ->
        nil
    end

    state =
      state
      |> Map.put(:reset, 0)
      |> Map.put(:remaining, @limit)

    handle_call(:queue, from, state)
  end

  def handle_call(:queue, _from, %{remaining: remaining} = state) do
    state = %{state | remaining: remaining - 1}

    state =
      if remaining == @limit do
        %{state | reset: :os.system_time(:seconds) + @reset}
      else
        state
      end

    {:reply, :ok, state}
  end
end
