defmodule Crux.Gateway.Connection.Producer do
  @moduledoc """
    Handles dispatching of packets received from the gateway.

    Every gateway has its own producer, defaults to `GenStage.BroadcastDispatcher`s.

    The dispatcher can be overriden via app config or passed override in `Crux.Gateway.start/1`.
    The key is `:dispatcher`, value should be a valid `GenStage.Dispatcher`, or a tuple of one and initial state.

    > For more informations regarding Consumers and Producers consult `GenStage`'s docs.
  """

  use GenStage

  @registry Crux.Gateway.Registry

  @doc """
    Computes a map of all producers keyed by shard_id.

    Values are either a `t:pid/0` or, if for some reason the producer could not be found, `:not_found`.
  """
  @spec producers() :: %{
          optional(non_neg_integer) => pid() | :not_found
        }
  def producers do
    Application.fetch_env!(:crux_gateway, :shards)
    |> Map.new(fn shard_id ->
      pid =
        with [{pid, _other}] when is_pid(pid) <-
               Registry.lookup(@registry, {shard_id, :producer}),
             true <- Process.alive?(pid) do
          pid
        else
          _ ->
            :not_found
        end

      {shard_id, pid}
    end)
  end

  @doc false
  def start_link(shard_id) do
    name = {:via, Registry, {@registry, {shard_id, :producer}}}

    GenStage.start_link(__MODULE__, nil, name: name)
  end

  @doc false
  def dispatch(%{t: type, d: data}, shard_id) do
    with [{pid, _other}] <- Registry.lookup(@registry, {shard_id, :producer}),
         true <- Process.alive?(pid) do
      GenStage.cast(pid, {:dispatch, {type, data, shard_id}})
    else
      _ ->
        require Logger
        Logger.warn("Missing producer for shard #{shard_id}; #{type}")
    end
  end

  # Queue
  # rear - tail (in)
  # elements
  # elements
  # more elements
  # front - head (out)

  @doc false
  def init(_state) do
    dispatcher = Application.fetch_env!(:crux_gateway, :dispatcher)
    {:producer, {:queue.new(), 0}, dispatcher: dispatcher}
  end

  @doc false
  def handle_cast({:dispatch, event}, {queue, demand}) do
    event
    |> :queue.in(queue)
    |> dispatch_events(demand, [])
  end

  @doc false
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
