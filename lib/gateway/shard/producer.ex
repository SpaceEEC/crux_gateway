defmodule Crux.Gateway.Shard.Producer do
  @moduledoc false

  use GenStage

  alias Crux.Gateway.Registry

  def start_link(opts) do
    name =
      opts.name
      |> Registry.name()
      |> Registry.via_producer(opts.shard_id, opts.shard_count)

    GenStage.start_link(__MODULE__, opts, name: name)
  end

  def dispatch(%{name: name, shard_id: shard_id, shard_count: shard_count}, data) do
    name
    |> Registry.name()
    |> Registry.lookup_producer(shard_id, shard_count)
    |> case do
      :error -> :error
      pid -> GenStage.cast(pid, {:dispatch, data})
    end
  end

  @impl GenStage
  def init(opts) do
    dispatcher = Map.get(opts, :dispatcher, GenStage.DemandDispatcher)

    {:producer, nil, dispatcher: dispatcher}
  end

  @impl GenStage
  def handle_cast({:dispatch, data}, state) do
    {:noreply, [data], state}
  end

  @impl GenStage
  def handle_demand(_demant, state) do
    {:noreply, [], state}
  end
end
