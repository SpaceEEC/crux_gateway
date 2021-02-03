defmodule Crux.Gateway.Shard do
  @moduledoc false

  require Logger

  use Supervisor

  alias Crux.Gateway.Connection
  alias Crux.Gateway.RateLimiter
  alias Crux.Gateway.Registry
  alias Crux.Gateway.Shard.Producer

  @shard_opts_keys ~w/intents presence session_id seq shard_id shard_count/a

  def child_spec(shard_opts) do
    {id, shard_opts} =
      case shard_opts do
        {shard_id, shard_count} = id ->
          {id, %{shard_id: shard_id, shard_count: shard_count}}

        %{shard_id: shard_id, shard_count: shard_count} = shard_opts ->
          {{shard_id, shard_count}, shard_opts}
      end

    %{
      id: id,
      start: {__MODULE__, :start_link, [shard_opts]},
      type: :supervisor
    }
  end

  def start_link(opts, shard_opts) do
    opts =
      Map.merge(
        opts,
        Map.take(shard_opts, @shard_opts_keys)
      )

    check_opts!(opts)

    name =
      opts.name
      |> Registry.name()
      |> Registry.via_shard(opts.shard_id, opts.shard_count)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    Logger.debug(fn ->
      "Starting shard supervisor for {#{opts.shard_id}, #{opts.shard_count}}."
    end)

    children = [
      {Producer, opts},
      {RateLimiter,
       type: :command, shard_id: opts.shard_id, shard_count: opts.shard_count, name: opts.name},
      {Connection, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp check_opts!(%{shard_id: shard_id})
       when not is_integer(shard_id)
       when shard_id < 0 do
    raise ArgumentError, """
    Expected :shard_id to be a not negative integer.

    Received: #{inspect(shard_id)}
    """
  end

  defp check_opts!(%{shard_count: shard_count})
       when not is_integer(shard_count)
       when shard_count <= 0 do
    raise ArgumentError, """
    Expected :shard_count to be a positive integer.

    Received: #{inspect(shard_count)}
    """
  end

  defp check_opts!(%{shard_id: shard_id, shard_count: shard_count})
       when shard_id > shard_count do
    raise ArgumentError, """
    Expected :shard_id to not be greater than :shard_count.

    Received: #{shard_id} > #{shard_count}
    """
  end

  defp check_opts!(opts)
       when not is_map_key(opts, :intents) do
    raise ArgumentError, """
    :intents was not provided when starting Crux.Gateway and is not provided when starting this shard.

    It must be provided in at least one of these.
    """
  end

  defp check_opts!(%{presence: presence})
       when not is_function(presence, 2) and not is_map(presence) and not is_nil(presence) do
    raise ArgumentError, """
    Expected :presence to be either a map or a function with an arity of 2.

    Received: #{inspect(presence)}
    """
  end

  defp check_opts!(%{session_id: session_id})
       when not is_binary(session_id) and not is_nil(session_id) do
    raise ArgumentError, """
    Expected :session_id to be a string.

    Received: #{inspect(session_id)}
    """
  end

  defp check_opts!(%{seq: seq})
       when not is_binary(seq) and not is_nil(seq) do
    raise ArgumentError, """
    Expected :seq to be a string.

    Received: #{inspect(seq)}
    """
  end

  defp check_opts!(%{} = opts), do: opts
end
