defmodule Crux.Gateway.Connection.Supervisor do
  @moduledoc false

  alias Crux.Gateway.{Connection, Util}

  use Supervisor

  @doc """
    Starts a `Crux.Gateway.Connection.Supervisor` process linked to the current process.
  """
  @spec start_link(args :: term()) :: Supervisor.on_start()
  def start_link(args), do: Supervisor.start_link(__MODULE__, args)

  @spec init(term()) :: {:ok, {:supervisor.sup_flags(), [:supervisor.child_spec()]}} | :ignore
  def init(args) do
    args = Map.put(args, :sup, self())

    dispatcher = Map.get(args, :dispatcher, GenStage.BroadcastDispatcher)

    children = [
      Connection.RateLimiter,
      {Connection.Producer, dispatcher},
      {Connection, args}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec get_rate_limiter(sup :: GenServer.server()) :: pid() | :error
  def get_rate_limiter(sup), do: Util.get_pid(sup, Connection.RateLimiter)

  @spec get_producer(sup :: GenServer.server()) :: pid() | :error
  def get_producer(sup), do: Util.get_pid(sup, Connection.Producer)

  @spec get_connection(sup :: GenServer.server()) :: pid() | :error
  def get_connection(sup), do: Util.get_pid(sup, Connection)
end
