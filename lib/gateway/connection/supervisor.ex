defmodule Crux.Gateway.Connection.Supervisor do
  @moduledoc false

  use Supervisor

  @registry Crux.Gateway.Registry

  def start_link(%{shard_id: shard_id} = args) do
    name = {:via, Registry, {@registry, {shard_id, :supervisor}}}
    Supervisor.start_link(__MODULE__, args, name: name)
  end

  def init(%{shard_id: shard_id} = args) do
    children = [
      Supervisor.child_spec(
        {Crux.Gateway.Connection.RateLimiter, shard_id},
        id: "rate_limiter_#{shard_id}"
      ),
      Supervisor.child_spec(
        {Crux.Gateway.Connection.Producer, shard_id},
        id: "producer_#{shard_id}"
      ),
      Supervisor.child_spec(
        {Crux.Gateway.Connection, args},
        id: "connection_#{shard_id}"
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
