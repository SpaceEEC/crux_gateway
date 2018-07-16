defmodule Crux.Gateway do
  @moduledoc """
  Main entry point to start the Gateway connection.

  Required for this to run are:
  - `:token` to identify with, you can get your bot's from [here](https://discordapp.com/developers/applications/me).
  > You want to keep that token secret at all times.

  - `:url` to connect to. Probably something like `wss://gateway.discord.gg`.
  (Do not append query strings)
  > You usually want to GET the url via `/gateway/bot` along the recommended shard count.

  - `:shard_count` you plan to run altogether.
  > Can and probably should be retrieved via `/gateway/bot`.

  - Optionally `:shards`, which has to be a list of numbers and ranges.

  Examples: `[1..3]` `[1, 2, 3]` `[1..3, 8, 9]`
  > If omitted all shards will be run.

  - Optionally `:dispatcher`, which has to be a valid `GenStage.Dispatcher` or a tuple of one and initial state.
  > See `Crux.Gateway.Connection.Producer` for more info.
  """

  @typedoc """
  Used to specify or override gateway options when initially starting the connection.

  See `start/1`
  """
  @type gateway_options :: %{
          optional(:token) => String.t(),
          optional(:url) => String.t(),
          optional(:shard_count) => pos_integer(),
          optional(:shards) => [non_neg_integer() | Range.t()],
          optional(:dispatcher) => GenStage.Dispatcher.t() | {GenStage.Dispatcher.t(), term()}
        }

  @doc """
  Initialises the connection(s) and actually starts the gateway.

  You can specify or override `:token`, `:url`, `:shard_count` and `:shards` here via `t:gateway_options`.
  """
  @spec start(args :: gateway_options()) :: [Supervisor.on_start_child()]
  def start(args \\ %{}) do
    :application.ensure_started(:crux_gateway)

    producer = Map.get(args, :dispatcher, GenStage.BroadcastDispatcher)
    Application.put_env(:crux_gateway, :dispatcher, producer)

    shard_count = fetch_or_put_env(args, :shard_count, &is_number/1)

    shards =
      case Application.fetch_env(:crux_gateway, :shards) do
        :error ->
          shards = Enum.to_list(0..(shard_count - 1))
          Application.put_env(:crux_gateway, :shards, shards)

          shards

        {:ok, shards} when is_list(shards) ->
          shards =
            shards
            |> Enum.flat_map(&map_shard/1)
            |> Enum.uniq()
            |> Enum.sort()

          if Enum.min(shards) < 0 do
            raise """
            Specified shards are out of range.
            A negative shard id is not valid

            :shards resolved to:
            #{inspect(shards)}
            """
          end

          if Enum.max(shards) >= shard_count do
            raise """
            Specified shards are out of range.
            Shard ids must be lower than shard_count

            :shards resolved to:
            #{inspect(shards)}
            """
          end

          Application.put_env(:crux_gateway, :shards, shards)

          shards

        _ ->
          raise_shards()
      end

    %{
      url: fetch_or_put_env(args, :url, &is_bitstring/1),
      token: fetch_or_put_env(args, :token, &is_bitstring/1),
      shard_count: shard_count
    }
    |> Crux.Gateway.Supervisor.start_gateway(shards)
  end

  defp fetch_or_put_env(args, atom, validator) do
    value =
      case args do
        %{^atom => value} ->
          Application.put_env(:crux_gateway, atom, value)

          value

        _ ->
          Application.fetch_env!(:crux_gateway, atom)
      end

    if validator.(value) do
      value
    else
      raise """
      :#{inspect(atom)} is not of the correct type.

      Received:
      #{inspect(value)}
      """
    end
  end

  defp map_shard(num) when is_number(num), do: [num]
  defp map_shard(%Range{} = range), do: range

  defp map_shard(other) do
    """

    Faulty element:
    #{inspect(other)}
    """
    |> raise_shards()
  end

  defp raise_shards(suffix \\ "") do
    raise """
          :shards must be a list of numbers and/or ranges

          Received :shards value:
          #{inspect(Application.fetch_env!(:crux_gateway, :shards))}
          """ <> suffix
  end
end
