defmodule Crux.Gateway.Registry do
  @moduledoc false

  use Crux.Gateway.Registry.Generator

  def name(name), do: Module.concat(name, :Registry)
  def identify_limiter_name(name), do: Module.concat(name, :IdentifyLimiter)
  def shard_supervisor_name(name), do: Module.concat(name, :ShardSupervisor)

  # Supervisor for the other processes
  registered_name(:shard, [:shard_id, :shard_count])
  # Manages the actual WebSocket connection
  registered_name(:connection, [:shard_id, :shard_count])
  # The rate limiter for user-sent commands.
  registered_name(:command, [:shard_id, :shard_count])
  # The producer to dispatch dispatch events to.
  registered_name(:producer, [:shard_id, :shard_count])
end
