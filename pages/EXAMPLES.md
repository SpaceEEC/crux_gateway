# Examples

## Small Everything

A simple example of Crux.Gateway in combination with Crux.Rest and Crux.Structures,
although with small adjustments this would work fine without.

### Application Supervisor
The first component: The Application Supervisor,
the gateway can be started at whatever supervisor level however.

```elixir
defmodule MyApp.Application do
  use Application

  def start(_, _) do
    children = [
        {MyApp.Rest, token: MyApp.token!()}, # Assuming that MyApp.Rest is a module using Crux.Rest
        {Crux.Gateway, &gateway_config/0}, # This function is evaluated once when Crux.Gateway is started
        MyApp.ConsumerSupervisor
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.init(children, opts)
  end

  defp gateway_config() do
    %{url: url, shards: shards, session_start_limit: %{max_concurrency: max_concurrency}} =
      MyApp.Rest.get_gateway_bot!()
    
    %{
      max_concurrency: max_concurrency,
      intents: Crux.Structs.Intents.resolve(:guild_messages),
      name: MyApp.Gateway,
      token: MyApp.token!(),
      url: url,
      shards: for(shard_id <- 0..(shards - 1), do: {shard_id, shards})
    }
  end
end
```

### Consumer Supervisor

The second component: The Consumer Supervisor for gateway dispatches.

This is pretty much just boilerplate code:
```elixir
defmodule MyApp.ConsumerSupervisor do
  use ConsumerSupervisor

  def start_link(arg) do
    ConsumerSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    pids =
      MyApp.Gateway
      |> Crux.Gateway.producers()
      |> Map.values()

    opts = [strategy: :one_for_one, subscribe_to: pids]
    ConsumerSupervisor.init([MyApp.Consumer], opts)
  end
end
```

### Consumer

The third and last component: The consumer.

This module is actually handling the incoming gateway dispatches.
This small example is just replying with `Pong!` whenever a non-bot user sends `!ping` in any channel.

```elixir
defmodule MyApp.Consumer do
  require Logger

  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :temporary # or :transient, if you want the process to restart on crashes
    }
  end

  def start_link({type, data, shard}) do
    Task.start_link(
      __MODULE__,
      :handle_event,
      [type, data, shard]
    )
  end

  def handle_event(:READY, data, _shard) do
    Logger.info("Ready as #{data.user.username}##{data.user.discriminator} (#{data.user.id})")
  end

  # Ignore bots, like a good bot.
  def handle_event(:MESSAGE_CREATE, %{author: %{bot: true}}, _shard), do: :ok

  def handle_event(:MESSAGE_CREATE, %{channel_id: channel_id, content: "!ping"}, _shard) do
    MyApp.Rest.create_message(channel_id, content: "Pong!")
  end

  # Catch-all clause to avoid the process crashing on other events.
  def handle_event(_type, _data, _shard), do: :ok
end
```