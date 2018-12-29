# Crux.Gateway

Package providing a flexible gateway connection to the Discord API.

## Useful links

 - [Documentation](https://hexdocs.pm/crux_gateway/0.1.4/)
 - [Github](https://github.com/SpaceEEC/crux_gateway/)
 - [Changelog](https://github.com/SpaceEEC/crux_gateway/releases/tag/0.1.4/)
 - [Umbrella Development Documentation](https://crux.randomly.space/)

## Installation

The package can be installed by adding `crux_gateway` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:crux_gateway, "~> 0.1.4"}
  ]
end
```

## Usage

For example:

```elixir
  iex> Crux.Gateway.start(%{
     token: "your token goes, for example, here",
     url: "wss://gateway.discord.gg",
     shard_count: 1
   })
  [ok: #PID<0.187.0>]

  iex> defmodule Consumer do
     use GenStage

     def init(_) do
       producers = Crux.Gateway.Connection.Producer.producers() |> Map.values()
       {:consumer, nil, subscribe_to: producers}
     end

     def handle_events(events, _from, nil) do
       for {:MESSAGE_CREATE, message, _shard_id} <- events do
         IO.puts("#{message.author.username}##{message.author.discriminator}: #{message.content}")
       end

       {:noreply, [], nil}
     end
   end
   {:module, Consumer, <<...>>, {:handle_events, 3}}

   iex> GenStage.start(Consumer, nil)
   {:ok, #Pid<0.243.0>}
```