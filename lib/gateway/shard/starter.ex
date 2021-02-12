defmodule Crux.Gateway.Shard.Starter do
  @moduledoc false

  # Module to start initially shards in _sync_.

  # There probably is a better way to go about this, but I don't know it.

  alias Crux.Gateway.Shard.Supervisor, as: ShardSupervisor

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(%{name: name, shards: shards}) do
    for shard <- shards do
      {:ok, _pid} = ShardSupervisor.start_shard(name, shard)
    end

    :ignore
  end

  def start_link(%{}) do
    :ignore
  end
end
