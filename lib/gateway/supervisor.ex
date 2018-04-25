defmodule Crux.Gateway.Supervisor do
  @moduledoc false

  use Supervisor

  @registry Crux.Gateway.Registry

  def start_link(_args \\ []), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  def init(:ok),
    do: Supervisor.init([{Registry, keys: :unique, name: @registry}], strategy: :one_for_one)

  def start_gateway(args, shards) do
    require Logger
    Logger.info("[Crux][Gateway][Supervisor]: Starting shards: #{inspect(shards)}")

    for shard_id <- shards do
      args
      |> Map.put(:shard_id, shard_id)
      |> start_shard()
    end
  end

  def start_shard(%{shard_id: shard_id} = args) do
    Supervisor.start_child(
      __MODULE__,
      Supervisor.child_spec(
        {Crux.Gateway.Connection.Supervisor, args},
        id: shard_id
      )
    )
  end
end
