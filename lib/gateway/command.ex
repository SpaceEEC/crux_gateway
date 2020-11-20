defmodule Crux.Gateway.Command do
  # credo:disable-for-this-file Credo.Check.Readability.SinglePipe

  @moduledoc """
  Builds [Gateway Commands](https://discord.com/developers/docs/topics/gateway#commands-and-events-gateway-commands).
  Note: Only the sent ones can be found here.

  A list of available op codes:

  | OP Code | Name                  | Direction     |
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

  alias :erlang, as: Erlang
  alias :gun, as: Gun

  @typedoc """
    Encoded command ready to be sent to the gateway via `Crux.Gateway.Connection.send_command/3`.

    If you want to build custom commands (read: new commands not yet supported by crux_gateway),
    build a valid [Gateway Payload Structure](https://discord.com/developers/docs/topics/gateway#payloads-gateway-payload-structure)
    and `:erlang.term_to_binary/1` it, then finally wrap it in a `{:binary, your_binary_payload}` tuple.
  """
  @type command :: Gun.ws_frame()

  @doc """
  Builds a [Heartbeat](https://discord.com/developers/docs/topics/gateway#heartbeat) command.

  Used to signalize the server that the client is still alive and able to receive messages.
  """
  @spec heartbeat(sequence :: non_neg_integer() | nil) :: command()
  def heartbeat(sequence), do: finalize(sequence, 1)

  @doc """
    Builds an [Identify](https://discord.com/developers/docs/topics/gateway#identify) command.

    Used to identify the gateway connection and "log in".
  """
  @spec identify(
          data :: %{
            :shard_id => non_neg_integer(),
            :shard_count => pos_integer(),
            :token => String.t(),
            :intents => non_neg_integer(),
            optional(:presence) => Crux.Gateway.presence()
          }
        ) :: command()

  def identify(
        %{shard_id: shard_id, shard_count: shard_count, token: token, intents: intents} = args
      ) do
    presence =
      case args do
        %{presence: fun} when is_function(fun, 1) ->
          fun.(shard_id)

        %{presence: presence} when is_map(presence) ->
          presence

        %{presence: nil} ->
          %{}

        args when not is_map_key(args, :presence) ->
          %{}
      end

    presence = _update_status(presence)

    {os, name} = :os.type()

    %{
      "token" => token,
      "properties" => %{
        "$os" => Atom.to_string(os) <> " " <> Atom.to_string(name),
        "$browser" => "Crux",
        "$device" => "Crux"
      },
      "compress" => true,
      "large_threshold" => 250,
      "shard" => [shard_id, shard_count],
      "presence" => presence,
      "intents" => intents
    }
    |> finalize(2)
  end

  @doc """
  Builds a [Update Voice State](https://discord.com/developers/docs/topics/gateway#update-voice-state) command.

  Used to join, switch between, and leave voice channels and/or change self_mute or self_deaf states.
  """
  @spec update_voice_state(
          guild_id :: Crux.Structs.Snowflake.t(),
          channel_id :: Crux.Structs.Snowflake.t() | nil,
          states :: [{:self_mute, boolean()} | {:self_deaf, boolean()}]
        ) :: command()
  def update_voice_state(guild_id, channel_id \\ nil, states \\ []) do
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
    Builds a [Update Status](https://discord.com/developers/docs/topics/gateway#update-status) command.

    Used to update the status of the client, including activity.
  """
  @spec update_status(status :: String.t(), activities :: [activity()] | nil) :: command()
  def update_status(status, activities \\ nil) do
    %{status: status, activities: activities}
    |> _update_status()
    |> finalize(3)
  end

  # Helper function used from within identify/1.
  defp _update_status(presence) do
    presence
    |> Map.new(fn
      {k, v} when is_list(v) ->
        activites =
          Enum.map(v, fn activity -> Map.new(activity, fn {k, v} -> {to_string(k), v} end) end)

        {to_string(k), activites}

      {k, v} ->
        {to_string(k), v}
    end)
    |> Map.merge(%{"afk" => false, "since" => nil})
  end

  @doc """
  Builds a [Request Guild Members](https://discord.com/developers/docs/topics/gateway#request-guild-members) command.

  Used to request guild member for a specific guild.
  > Note: This must be sent to the connection handling the guild, otherwise the request will just be ignored.

  The gateway will respond with `:GUILD_MEMBER_CHUNK` packets until all appropriate members are received.
  """
  @spec request_guild_members(
          guild_id :: Crux.Structs.Snowflake.t(),
          opts ::
            [
              {:query, String.t()}
              | {:limit, non_neg_integer()}
              | {:presences, boolean()}
              | {:user_ids, Crux.Structs.Snowflake.t() | [Crux.Structs.Snowflake.t()]}
              | {:nonce, String.t()}
            ]
            | map()
        ) :: command()
  def request_guild_members(guild_id, opts \\ %{})

  def request_guild_members(guild_id, %{} = opts) do
    other_opts =
      case opts do
        %{query: query, user_ids: user_ids} -> %{"query" => query, "user_ids" => user_ids}
        %{query: query} -> %{"query" => query}
        %{user_ids: user_ids} -> %{"user_ids" => user_ids}
        %{} -> %{"query" => ""}
      end

    other_opts =
      case opts do
        %{nonce: nonce} -> Map.put(other_opts, :nonce, nonce)
        _ -> other_opts
      end

    %{
      "guild_id" => guild_id,
      "limit" => Map.get(opts, :limit, 0),
      "presences" => Map.get(opts, :presences, false)
    }
    |> Map.merge(other_opts)
    |> finalize(8)
  end

  def request_guild_members(guild_id, opts), do: request_guild_members(guild_id, Map.new(opts))

  @doc """
  Builds a [Resume](https://discord.com/developers/docs/topics/gateway#resume) command.

  Used to resume into a session which was unexpectly disconnected and may be resumable.
  """
  @spec resume(
          data :: %{
            seq: non_neg_integer(),
            token: String.t(),
            session_id: String.t()
          }
        ) :: command()
  def resume(%{seq: seq, token: token, session_id: session_id}) do
    %{
      "seq" => seq,
      "token" => token,
      "session_id" => session_id
    }
    |> finalize(6)
  end

  @spec finalize(
          data :: %{String.t() => map() | String.t()} | non_neg_integer() | nil,
          op :: integer()
        ) :: command()
  defp finalize(data, op) do
    data =
      %{
        "op" => op,
        "d" => data
      }
      |> Erlang.term_to_binary()

    {:binary, data}
  end
end
