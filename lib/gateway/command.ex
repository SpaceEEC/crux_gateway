defmodule Crux.Gateway.Command do
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
    Encoded command ready to be sent to the gateway via `Crux.Gateway.Connection.send_command/2`.

    If you want to build custom commands,
    pass `:erlang.term_to_binary/1` a map with the keys `op` and `d`,
    and wrap it in a tuple with `:binary` as first element.
  """
  @type gateway_command :: {:binary, binary()}

  @doc """
  Builds a [Heartbeat](https://discordapp.com/developers/docs/topics/gateway#heartbeat) command.

  Used to signalize the server that the client is still alive and able to receive messages.
  """
  @spec heartbeat(sequence :: integer()) :: gateway_command()
  def heartbeat(sequence), do: finalize(sequence, 1)

  @doc """
    Builds an [Identify](https://discordapp.com/developers/docs/topics/gateway#identify) command.

    Used to identify the gateway connection and "log in".
  """
  @spec identify(
          data :: %{
            :shard_id => non_neg_integer(),
            :shard_count => non_neg_integer(),
            :token => String.t()
          }
        ) :: gateway_command()

  def identify(%{shard_id: shard_id, shard_count: shard_count, token: token}) do
    {os, name} = :os.type()

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
      "shard" => [shard_id, shard_count],
      "presence" => %{
        "since" => 0,
        "game" => nil,
        "status" => "online",
        "afk" => false
      }
    }
    |> finalize(2)
  end

  @doc """
  Builds a [Voice State Update](https://discordapp.com/developers/docs/topics/gateway#voice-state-update) command.

  Used to join, switch between, and leave voice channels.
  """
  @spec voice_state_update(
          guild_id :: pos_integer(),
          channel_id :: pos_integer() | nil,
          states :: [{:self_mute, boolean()} | {:self_deaf, boolean()}]
        ) :: gateway_command()
  def voice_state_update(guild_id, channel_id \\ nil, states \\ []) do
    %{
      "guild_id" => guild_id,
      "channel_id" => channel_id,
      "self_mute" => states[:self_mute] || false,
      "self_deaf" => states[:self_deaf] || true
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
  @spec status_update(status :: String.t(), game :: activity()) :: gateway_command()
  def status_update(status, game \\ nil) do
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

  The gateway will respond with `:GUILD_MEMBER_CHUNK` (a) packet(s).
  """
  @spec request_guild_members(
          guild_id :: pos_integer(),
          opts :: [{:query, String.t()} | {:limit, pos_integer()}]
        ) :: gateway_command()
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
  @spec resume(data :: %{:seq => non_neg_integer(), token: String.t(), session: String.t()}) ::
          gateway_command()
  def resume(%{seq: seq, token: token, session: session}) do
    %{
      "seq" => seq,
      "token" => token,
      "session_id" => session
    }
    |> finalize(6)
  end

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
