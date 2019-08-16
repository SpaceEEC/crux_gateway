defmodule Crux.Gateway.Command do
  # credo:disable-for-this-file Credo.Check.Readability.SinglePipe

  @moduledoc """
  Builds [Gateway Commands](https://discordapp.com/developers/docs/topics/gateway#commands-and-events-gateway-commands).
  Note: Only the sent ones can be found here.

  A list of available op codes:

  | OP Code | Name                  |               |
  | ------- | --------------------- | ------------- |
  | 0       | dispatch              | received only |
  | 1       | heartbeat             | two way       |
  | 2       | identify              | sent only     |
  | 3       | status_update         | sent only     |
  | 4       | voice_state_update    | sent only     |
  | 5       | voice_guild_ping      | sent only     |
  | 6       | resume                | sent only     |
  | 7       | reconnect             | received only |
  | 8       | request_guild_members | sent only     |
  | 9       | invalid_session       | received only |
  | 10      | hello                 | received only |
  | 11      | heartbeat_ack         | received only |

  [Gateway Lifecycle Flowchart](https://s.gus.host/flowchart.svg)
  """

  @typedoc """
    Encoded command ready to be sent to the gateway via `Crux.Gateway.Connection.send_command/3`.

    If you want to build custom commands,
    pass `:erlang.term_to_binary/1` a map with the keys `op` and `d`,
    and wrap it in a tuple with `:binary` as first element.
  """
  @type command :: WebSockex.frame()

  @doc """
  Builds a [Heartbeat](https://discordapp.com/developers/docs/topics/gateway#heartbeat) command.

  Used to signalize the server that the client is still alive and able to receive messages.
  """
  @spec heartbeat(sequence :: integer()) :: command()
  def heartbeat(sequence), do: finalize(sequence, 1)

  @doc """
    Builds an [Identify](https://discordapp.com/developers/docs/topics/gateway#identify) command.

    Used to identify the gateway connection and "log in".
  """
  @spec identify(
          data :: %{
            :shard_id => non_neg_integer(),
            :shard_count => non_neg_integer(),
            :token => String.t(),
            optional(:presence) => Crux.Gateway.presence(),
            optional(:guild_subscriptions) => boolean()
          }
        ) :: command()

  def identify(%{shard_id: shard_id, shard_count: shard_count, token: token} = args) do
    presence =
      args
      |> get_presence(shard_id)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"since" => 0, "afk" => false})

    {os, name} = :os.type()
    guild_subscriptions = Map.get(args, :guild_subscriptions, true)

    %{
      "token" => token,
      "properties" => %{
        "$os" => Atom.to_string(os) <> " " <> Atom.to_string(name),
        "$browser" => "Crux",
        "$device" => "Crux",
        "$referring_domain" => "",
        "$referer" => ""
      },
      "compress" => true,
      "large_threshold" => 250,
      "guild_subscriptions" => guild_subscriptions,
      "shard" => [shard_id, shard_count],
      "presence" => presence
    }
    |> finalize(2)
  end

  defp get_presence(%{presence: %{} = presence}, _shard_id), do: presence

  defp get_presence(%{presence: presence}, shard_id) when is_function(presence, 1),
    do: presence.(shard_id)

  defp get_presence(_, _), do: %{"game" => nil, "status" => "online"}

  @doc """
  Builds a [Voice State Update](https://discordapp.com/developers/docs/topics/gateway#voice-state-update) command.

  Used to join, switch between, and leave voice channels and/or change self_mute or self_deaf states.
  """
  @spec voice_state_update(
          guild_id :: pos_integer(),
          channel_id :: pos_integer() | nil,
          states :: [{:self_mute, boolean()} | {:self_deaf, boolean()}]
        ) :: command()
  def voice_state_update(guild_id, channel_id \\ nil, states \\ []) do
    %{
      "guild_id" => guild_id,
      "channel_id" => channel_id,
      "self_mute" => Keyword.get(states, :self_mute, false),
      "self_deaf" => Keyword.get(states, :self_deaf, false)
    }
    |> finalize(4)
  end

  @typedoc """
  Used to set an activity via `status_update/2`.

  `:type` must be a valid [Activity Type](https://discordapp.com/developers/docs/topics/gateway#activity-object-activity-types)
  > Note that streaming requires a twitch url pointing to a possible channel!
  """
  @type activity :: %{
          :name => String.t(),
          :type => non_neg_integer(),
          optional(:url) => String.t()
        }

  @doc """
    Builds a [Status Update](https://discordapp.com/developers/docs/topics/gateway#update-status) command.

    Used to update the status of the client, including activity.
  """
  @spec status_update(status :: String.t(), game :: activity() | nil) :: command()
  def status_update(status, game \\ nil) do
    game =
      case game do
        %{} = game ->
          Map.new(game, fn {k, v} -> {to_string(k), v} end)

        nil ->
          nil
      end

    %{
      "afk" => false,
      "game" => game,
      "since" => 0,
      "status" => status
    }
    |> finalize(3)
  end

  @doc """
  Builds a [Request Guild Members](https://discordapp.com/developers/docs/topics/gateway#request-guild-members) command.

  Used to request guild member for a specific guild.
  > Note: This must be sent to the connection handling the guild, not just any connection.

  The gateway will respond with `:GUILD_MEMBER_CHUNK` packets until all appropriate members are received.
  """
  @spec request_guild_members(
          guild_id :: pos_integer(),
          opts :: [{:query, String.t()} | {:limit, pos_integer()}]
        ) :: command()
  def request_guild_members(guild_id, opts \\ []) do
    %{
      "guild_id" => guild_id,
      "query" => opts[:query] || "",
      "limit" => opts[:limit] || 0
    }
    |> finalize(8)
  end

  @doc """
  Builds a [Resume](https://discordapp.com/developers/docs/topics/gateway#resume) command.

  Used to resume into a session which was unexpectly disconnected and may be resumable.
  """
  @spec resume(
          data :: %{
            :seq => non_neg_integer(),
            token: String.t(),
            session: String.t()
          }
        ) :: command()
  def resume(%{seq: seq, token: token, session: session}) do
    %{
      "seq" => seq,
      "token" => token,
      "session_id" => session
    }
    |> finalize(6)
  end

  @spec finalize(
          data :: %{String.t() => map() | String.t()},
          op :: integer()
        ) :: command()
  defp finalize(data, op) do
    data =
      %{
        "op" => op,
        "d" => data
      }
      |> :erlang.term_to_binary()

    {:binary, data}
  end
end
