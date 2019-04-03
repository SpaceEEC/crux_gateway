# Crux.Gateway

Library providing a flexible gateway connection to the Discord API.

## Useful links

 - [Documentation](https://hexdocs.pm/crux_gateway/0.2.0/)
 - [Github](https://github.com/SpaceEEC/crux_gateway/)
 - [Changelog](https://github.com/SpaceEEC/crux_gateway/releases/tag/0.2.0/)
 - [Umbrella Development Documentation](https://crux.randomly.space/)

## Installation

The library can be installed by adding `crux_gateway` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:crux_gateway, "~> 0.2.0"}
  ]
end
```

## Usage

For example:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_, _) do
    children = [
      {Crux.Gateway,
       {%{
          token: "your token",
          url: "current gateway url",
          shard_count: 1
        }, name: MyApp.Gateway}},
      MyApp.Consumer
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

```elixir
defmodule MyApp.Consumer do
  use GenStage

  def start_link(args) do
    GenStage.start_link(__MODULE__, args)
  end

  def init(args) do
    pids = Crux.Gateway.Connection.Producer.producers(MyApp.Gateway) |> Map.values()
    {:consumer, args, subscribe_to: pids}
  end

  def handle_events(events, _from, state) do
    for {type, data, shard_id} <- events do
      handle_event(type, data, shard_id)
    end

    {:noreply, [], state}
  end

  def handle_event(
        :MESSAGE_CREATE,
        %{content: "ping", author: %{username: username, discriminator: discriminator}},
        _shard_id
      ) do
    IO.puts("Received a ping from #{username}##{discriminator}!")
  end

  def handle_event(_, _, _), do: nil
end
```