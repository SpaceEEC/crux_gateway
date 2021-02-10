defmodule Crux.Gateway do
  @moduledoc """
  Main entry point for `Crux.Gateway`.

  This module fits under a supervision tree, see `start_link/1` for configuration options.
  """
  @moduledoc since: "0.1.0"

  use Supervisor

  alias Crux.Gateway.Command
  alias Crux.Gateway.Connection
  alias Crux.Gateway.RateLimiter
  alias Crux.Gateway.Registry
  alias Crux.Gateway.Shard.Supervisor, as: ShardSupervisor

  ###
  # Opts
  ###

  @typedoc """
  The id of a shard, shards are identified by a tuple of shard id and shard count.
  """
  @typedoc since: "0.3.0"
  @type shard_id :: non_neg_integer()

  @typedoc """
  The shard count of a shard, shards are identified by a tuple of shard id and shard count.
  """
  @typedoc since: "0.3.0"
  @type shard_count :: pos_integer()

  @typedoc """
  A tuple of shard id and shard count used to identify a shard.
  """
  @typedoc since: "0.3.0"
  @type shard_tuple :: {shard_id(), shard_count()}

  @typedoc """
  The given name for a `Crux.Gateway` process.
  """
  @typedoc since: "0.2.0"
  @type gateway :: atom()
  @typedoc """
  Used as initial presence for every session.
  Can be either a map representing the presence to use or a function taking the shard id and the shard count and returning a presence map to use.
  """
  @typedoc since: "0.2.0"
  @type presence :: presence_map() | (shard_id(), shard_count() -> presence_map())

  @typedoc "See `t:presence/0`."
  @typedoc since: "0.3.0"
  @type presence_map :: %{
          optional(:status) => String.t(),
          optional(:activites) => [Command.activity()]
        }

  @typedoc """
  Type for events published by `Crux.Gateway`'s shard gen stage stages.

  For example: `{:MESSAGE_CREATE, %{...}, {0, 1}}`
  """
  @doc since: "0.3.0"
  @type event :: {type :: atom(), data :: term(), shard_tuple()}

  @typedoc """
  Required to start `Crux.Gateway`.

  These can optionally be a function for lazy loading, said function is applied exactly once with no arguments when the process is started.

  # Required
  - `:name` - The name to use for the `Crux.Gateway` process.
  - `:token` - The bot token to use, you can get the one of your bot from [here](https://discord.com/developers/applications).
  - `:url` - The gateway URL to connect to (must use the wss protocol), obtained from `/gateway/bot` (See also `c:Crux.Rest.get_gateway_bot/0`)

  # Optional
  - `:intents` - The types of events you would like to receive from Discord. (See also `Crux.Structs.Intents`)
  - > If none are provided here, you must provide them when starting a shard.
  - `:shards` - Initial shards to launch on startup.
  - `:presence` - Used as initial presence for every session. (See also `t:presence/0`)
  - > Defaults to none (the bot will be online with no activity)
  - `:max_concurrency` - How many shards may identify within 5 seconds, obtained from `/gateway/bot` (See also `c:Crux.Rest.get_gateway_bot/0`)
  - > Defaults to `1`
  - `:dispatcher` - An atom representing a dispatcher module or a tuple of one and inital options.
  - > Defaults to `GenStage.DemandDispatcher`.

  """
  @typedoc since: "0.3.0"
  @type opts :: opts_map() | (() -> opts_map())

  @typedoc "See `t:opts/0`."
  @typedoc since: "0.3.0"
  @type opts_map ::
          %{
            optional(:intents) => non_neg_integer(),
            optional(:presence) => presence(),
            optional(:shards) => [shard_tuple() | shard_opts()],
            optional(:max_concurrency) => pos_integer(),
            optional(:dispatcher) => module() | {module(), GenStage.Dispatcher.options()},
            name: gateway(),
            token: String.t(),
            url: String.t()
          }
          | keyword()

  @typedoc """
  Used to start a shard.

  # Required
  - `:shard_id` - The id of the shard you want to start.
  - `shard_count` - The shard count of the shard you want to start.
  - `:intents` - What kind of events you would like to receive. (See also `Crux.Structs.Intents`)
  - > Optional when specified in `t:opts/0`, if specified here anyway, this value will override the former.

  # Optional
  - `:intents` - What events you would like to receive from Discord. (See also `Crux.Structs.Intents`)
  - > Required when not specified in `t:opts/0`, if specified here anyway, this value will override the former.
  - `:presence` - Used as initial presence for every session. (See also `t:presence/0`)
  - > If present this will override the presenve provided when starting `Crux.Gateway`.
  - `:session_id` - If you want to (try to) resume a disconnected session, this also requires `:seq` to be set.
  - `:seq` - If you want to (try to) resume a disconnected session, this also requires `:session_id` to be set.
  """
  @typedoc since: "0.3.0"
  @type shard_opts :: %{
          optional(:intents) => non_neg_integer(),
          optional(:presence) => presence(),
          optional(:session_id) => String.t(),
          optional(:seq) => pos_integer(),
          shard_id: shard_id(),
          shard_count: shard_count()
        }

  ###
  # Client API
  ###

  @doc """
  Start a shard.
  """
  @doc since: "0.3.0"
  @spec start_shard(gateway(), shard_tuple() | shard_opts()) :: Supervisor.on_start_child()
  defdelegate start_shard(name, shard), to: ShardSupervisor

  @doc """
  Stop a shard.
  """
  @doc since: "0.3.0"
  @spec stop_shard(gateway, shard_tuple()) :: :ok | {:error, :not_found}
  defdelegate stop_shard(name, shard), to: ShardSupervisor

  @doc """
  A map of all running shard supervisors.
  """
  @doc since: "0.3.0"
  @spec shards(gateway()) :: %{required(shard_tuple()) => pid()}
  defdelegate shards(name), to: ShardSupervisor

  @doc """
  A map of all running producers.

  See `t:event/0` for the type of published event.
  """
  @doc since: "0.3.0"
  @spec producers(gateway()) :: %{required(shard_tuple()) => pid()}
  defdelegate producers(name), to: ShardSupervisor

  @doc """
  Send a command to Discord through the specified shard.

  Errors:
  - `:not_found` - The connection process for the given shard tuple wasn't found. (That shard likely wasn't started, or happened to just crash.)
  - `:no_rate_limiter` - The connection was found, but its rate limiter wasn't. (This means it crashed, that shouldn't happen.)
  - `:not_ready` - The connection is currently not ready, try again later.
  - `:too_large` - The given command was too large. (You shouldn't exceed this, the payload likely is invalid anyway.)
  """
  @doc since: "0.3.0"
  @spec send_command(
          gateway(),
          shard_tuple(),
          Crux.Gateway.Command.command()
        ) :: :ok | {:error, :not_found | :no_rate_limiter | :not_ready | :too_large}
  defdelegate send_command(gateway, shard_tuple, packet), to: Connection

  ###
  # Start
  ###

  @doc """
  Start this module linked to the current process, intended to be used in combination with a Supervisor.
  """
  @spec start_link(opts()) :: Supervisor.on_start()
  def start_link(opts) do
    opts =
      case opts do
        %{} = opts -> opts
        opts when is_list(opts) -> Map.new(opts)
        opts when is_function(opts, 0) -> %{} = opts.()
      end

    check_opts!(opts)

    Supervisor.start_link(__MODULE__, opts, name: opts.name)
  end

  @spec child_spec(opts()) :: Supervisor.child_spec()

  ###
  # Server API
  ###

  @impl Supervisor
  def init(opts) do
    children = [
      {Elixir.Registry, keys: :unique, name: Registry.name(opts.name), meta: [opts: opts]},
      {RateLimiter,
       type: :identify, max_concurrency: Map.get(opts, :max_concurrency, 1), name: opts.name},
      {ShardSupervisor, opts},
      {Task, shard_starter(opts)}
    ]

    opts = [strategy: :rest_for_one]
    Supervisor.init(children, opts)
  end

  defp shard_starter(%{name: name, shards: shards}) do
    fn ->
      for shard <- shards do
        {:ok, _pid} = ShardSupervisor.start_shard(name, shard)
      end
    end
  end

  defp shard_starter(%{}), do: fn -> :ok end

  defp check_opts!(%{shards: shards})
       when not is_list(shards) do
    raise ArgumentError, """
    Expected :shards to be a list.

    Received: #{inspect(shards)}
    """
  end

  defp check_opts!(%{max_concurrency: max_concurrency})
       when not is_integer(max_concurrency)
       when max_concurrency <= 0 do
    raise ArgumentError, """
    Expected :max_concurrency to be a positive integer.

    Received: #{inspect(max_concurrency)}
    """
  end

  defp check_opts!(%{presence: presence})
       when not is_map(presence) and not is_function(presence, 2) do
    raise ArgumentError, """
    Expected :presence to be either a map or a function with an arity of 2.

    Received: #{inspect(presence)}
    """
  end

  defp check_opts!(%{intents: intents})
       when not is_integer(intents)
       when intents < 0 do
    raise ArgumentError, """
    Expected :intents to be an not negative integer.

    Received: #{inspect(intents)}
    """
  end

  defp check_opts!(%{name: name})
       when not is_atom(name) do
    raise ArgumentError, """
    Expected :name to be an atom.

    Received: #{inspect(name)}
    """
  end

  defp check_opts!(%{token: token})
       when not is_binary(token) do
    raise ArgumentError, """
    Expected :token to be a string.

    Received: #{inspect(token)}
    """
  end

  defp check_opts!(%{url: url})
       when not is_binary(url) do
    raise ArgumentError, """
    Expected :url to be a string.

    Received: #{inspect(url)}
    """
  end

  defp check_opts!(opts)
       when not is_map_key(opts, :name) do
    raise ArgumentError, """
    The :name option is required.
    """
  end

  defp check_opts!(opts)
       when not is_map_key(opts, :token) do
    raise ArgumentError, """
    The :token option is required.
    """
  end

  defp check_opts!(opts)
       when not is_map_key(opts, :url) do
    raise ArgumentError, """
    The :url option is required.
    """
  end

  defp check_opts!(opts), do: opts
end
