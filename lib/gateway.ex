defmodule Crux.Gateway do
  @moduledoc """
    Main entry point for `Crux.Gateway`.

    This module fits under a supervision tree, see `start_link/1` arguments for configuration.
  """

  use Supervisor

  alias Crux.Gateway.{Connection, IdentifyLimiter, Util}

  @typedoc """
    Used as initial presence for every session.
  """
  @type presence :: (non_neg_integer() -> map()) | map()

  @typedoc """
    The gateway reference
  """
  @type gateway :: Supervisor.supervisor()

  @doc """
    Starts a `Crux.Gateway` process linked to the current process.

    Options are either just `t:options/0` or a tuple of `t:options/0` and `t:Supervisor.options/0`.
  """
  @spec start_link(
          opts_or_tuple ::
            options()
            | {options(), Supervisor.options()}
        ) :: Supervisor.on_start()
  def start_link({gateway_opts, gen_opts}) do
    Supervisor.start_link(__MODULE__, gateway_opts, gen_opts)
  end

  def start_link(gateway_opts) do
    Supervisor.start_link(__MODULE__, gateway_opts)
  end

  @typedoc """
    Used to start `Crux.Gateway`.

    See `start_link/1`

    Notes:
    - `:token` can be retrieved from [here](https://discordapp.com/developers/applications/me).

    - `:url` you can GET from `/gateway/bot` (or `c:Crux.Rest.gateway_bot/0`).

    - `:shard_count` same as `:url`.

    - Optionally `:shards`, which has to be a list of numbers and ranges.
      Examples: `[1..3]`, `[1, 2, 3]`, `[1..3, 8, 9]`
      > Defaults to `0..shard_count-1`.

    - Optionally `:presence`, which is used for the initial presence of every session.
      This should be a map with a `"game"` and `"status"` key, or a function with an arity of one (the shard id) and returning such a map, or `nil` for the default.
      If a function, it will be invoked whenever a shard is about to identify.
      > Defaults to `%{"game" => nil, "status" => "online"}`.

    - Optionally `:guild_subscriptions`, aids large or generally stateless bots by opting out of several events and less data being sent over the gateway.
      For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-subscriptions) and the relevant PR on [GitHub](https://github.com/discordapp/discord-api-docs/pull/1016).
      > Defaults to `true`

    - Optionally `:dispatcher`, which has to be a valid `GenStage.Dispatcher` or a tuple of one and initial state.
      See `Crux.Gateway.Connection.Producer` for more info.
      > Defaults to `GenStage.BroadcastDispatcher`
  """
  @type options ::
          %{
            required(:token) => String.t(),
            required(:url) => String.t(),
            required(:shard_count) => pos_integer(),
            optional(:shards) => [non_neg_integer() | Range.t()],
            optional(:presence) => presence(),
            optional(:guild_subscriptions) => boolean(),
            optional(:dispatcher) => GenStage.Dispatcher.t() | {GenStage.Dispatcher.t(), term()}
          }
          | list()

  @doc false
  @spec init(term()) :: {:ok, tuple()}
  def init(opts) when is_list(opts), do: opts |> Map.new() |> init()

  def init(%{} = opts) do
    gateway_opts =
      opts
      |> transform_opts()
      |> Map.put(:gateway, self())

    shards =
      for shard_id <- gateway_opts.shards do
        opts = Map.put(gateway_opts, :shard_id, shard_id)

        Supervisor.child_spec({Connection.Supervisor, opts}, id: shard_id)
      end

    children = [
      IdentifyLimiter
      | shards
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec get_limiter(gateway()) :: pid() | :error
  def get_limiter(gateway), do: Util.get_pid(gateway, IdentifyLimiter)

  @doc false
  @spec get_shard(gateway(), id :: non_neg_integer()) :: pid() | :error
  def get_shard(gateway, id) when is_integer(id), do: Util.get_pid(gateway, id)

  @doc false
  @spec get_shards(gateway()) :: %{required(non_neg_integer()) => pid()} | :error
  def get_shards(gateway) do
    gateway
    |> Supervisor.which_children()
    |> Enum.filter(fn
      {id, _pid, _type, _module} when is_integer(id) -> true
      _ -> false
    end)
    |> Map.new(fn {id, pid, _type, _module} -> {id, pid} end)
  end

  defp transform_opts(
         %{
           shard_count: shard_count,
           url: url,
           token: token
         } = opts
       )
       when is_number(shard_count) and shard_count > 0 and is_binary(url) and is_binary(token) do
    opts = transform_shards(opts, shard_count)

    if Map.has_key?(opts, :presence) do
      :ok = validate_presence(opts.presence)
    end

    if Map.has_key?(opts, :guild_subscriptions) do
      :ok = validate_guild_subscriptions(opts.guild_subscriptions)
    end

    opts
  end

  defp transform_shards(%{shards: shards} = opts, shard_count) do
    shards =
      shards
      |> Enum.flat_map(&map_shard(&1, shards))
      |> Enum.uniq()
      |> Enum.sort()

    if Enum.min(shards) < 0 do
      raise """
      :shards are out of range.
      A negative shard id is not valid

      :shards resolved to:
      #{inspect(shards)}
      """
    end

    if Enum.max(shards) >= shard_count do
      raise """
      :shards are out of range.
      Shard ids must be lower than shard_count (#{shard_count})

      :shards resolved to:
      #{inspect(shards)}
      """
    end

    %{opts | shards: shards}
  end

  # No :shards to spawn provided, default to all shards
  defp transform_shards(opts, shard_count) do
    Map.put(opts, :shards, Enum.to_list(0..(shard_count - 1)))
  end

  defp map_shard(num, _shards) when is_number(num), do: [num]
  defp map_shard(%Range{} = range, _shards), do: range

  defp map_shard(other, shards) do
    """
    :shards must be a list of numbers and/or ranges

    Received :shards value:
    #{inspect(shards)}

    Faulty element:
    #{inspect(other)}
    """
  end

  defp validate_guild_subscriptions(valid) when is_boolean(valid), do: :ok

  defp validate_guild_subscriptions(invalid) do
    raise """
      :guild_subscriptions must be a boolean if present.

      Received:
      #{inspect(invalid)}
    """
  end

  defp validate_presence(%{}), do: :ok
  defp validate_presence(p) when is_function(p, 1), do: :ok
  defp validate_presence(nil), do: :ok

  defp validate_presence(other) do
    raise """
    :presence is not of the correct type.

    Received:
    #{inspect(other)}
    """
  end
end
