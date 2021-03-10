defmodule Crux.Gateway.Shard.Supervisor do
  @moduledoc false

  # Supervises the shard supervisors

  require Logger

  use DynamicSupervisor

  alias Crux.Gateway.Registry
  alias Crux.Gateway.Shard

  ###
  # Client API
  ###

  def start_link(opts) do
    name = Registry.shard_supervisor_name(opts.name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  def start_shard(name, opts) do
    name = Registry.shard_supervisor_name(name)
    DynamicSupervisor.start_child(name, {Shard, opts})
  end

  def stop_shard(name, {shard_id, shard_count}) do
    name
    |> Registry.name()
    |> Registry.lookup_shard(shard_id, shard_count)
    |> case do
      :error ->
        {:error, :not_found}

      pid ->
        name
        |> Registry.shard_supervisor_name()
        |> DynamicSupervisor.terminate_child(pid)
    end
  end

  def shards(name) do
    select_ids(name, :shard)
  end

  def producers(name) do
    select_ids(name, :producer)
  end

  defp select_ids(name, type) do
    name
    |> Registry.name()
    |> Elixir.Registry.select([
      {
        # Match {{process_type, shard_id, shard_count}, pid, _value}
        {{:"$1", :"$2", :"$3"}, :"$4", :_},
        # Guard process_type == type
        [{:==, :"$1", type}],
        # Return {{shard_id, shard_count}, pid}
        [{{{{:"$2", :"$3"}}, :"$4"}}]
      }
    ])
    |> Map.new()
  end

  ###
  # Server API
  ###

  @impl DynamicSupervisor
  def init(opts) do
    Logger.debug(fn -> "Starting shard supervisor supervisor." end)
    DynamicSupervisor.init(strategy: :one_for_one, extra_arguments: [opts])
  end
end
