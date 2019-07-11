defmodule Crux.Gateway.Connection.Producer do
  @moduledoc """
    Handles dispatching of packets received from the gateway.

    Every `Crux.Gateway.Connection` (shard) has its own producer, defaults to `GenStage.BroadcastDispatcher`s.

    The dispatcher can be overriden via `t:Crux.Gateway.options/0`

  > For more informations regarding Consumers and Producers consult `GenStage`'s documentation.
  """

  alias Crux.Gateway
  alias Crux.Gateway.Connection

  use GenStage

  @typep state :: {
           queue :: :queue.queue(request :: term()),
           demand :: non_neg_integer()
         }

  @doc false
  @spec start_link(args :: any()) :: GenServer.on_start()
  def start_link(args), do: GenStage.start_link(__MODULE__, args)

  @doc """
    Computes a map of all producer `t:pid/0`s keyed by shard_id.
  """
  @spec producers(gateway :: Crux.Gateway.gateway()) :: %{optional(non_neg_integer()) => pid()}
  def producers(gateway) do
    gateway
    |> Gateway.get_shards()
    |> Map.new(fn {id, sup} -> {id, Connection.Supervisor.get_producer(sup)} end)
  end

  @doc false
  @spec dispatch(sup :: Supervisor.supervisor(), event :: map(), shard_id :: pos_integer()) :: :ok
  def dispatch(sup, %{t: type, d: data}, shard_id) do
    sup
    |> Connection.Supervisor.get_producer()
    |> GenStage.cast({:dispatch, {type, data, shard_id}})
  end

  @doc false
  @spec init(term()) :: {:producer, state(), term()}
  def init(dispatcher) do
    state = {
      :queue.new(),
      # demand
      0
    }

    {:producer, state, dispatcher: dispatcher}
  end

  @doc false
  @spec handle_cast(term(), term()) :: {:noreply, list(), state()}
  def handle_cast({:dispatch, event}, {queue, demand}) do
    event
    |> :queue.in(queue)
    |> dispatch_events(demand, [])
  end

  @doc false
  @spec handle_demand(term(), term()) :: {:noreply, list(), state()}
  def handle_demand(incoming_demand, {queue, demand}) do
    dispatch_events(queue, incoming_demand + demand, [])
  end

  defp dispatch_events(queue, demand, events) do
    with d when d > 0 <- demand,
         {{:value, event}, queue} <- :queue.out(queue) do
      dispatch_events(queue, demand - 1, [event | events])
    else
      _ ->
        {:noreply, Enum.reverse(events), {queue, demand}}
    end
  end
end
