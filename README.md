# Crux.Gateway

Package providing a flexible gateway connection to the Discord API.

## Useful links

 - [Documentation](https://hexdocs.pm/crux_gateway/0.1.1/)
 - [Github](https://github.com/SpaceEEC/crux_gateway/)
 - [Changelog](https://github.com/SpaceEEC/crux_gateway/releases/tag/0.1.1/)
 - [Umbrella Development Documentation](https://crux.randomly.space/)

## Installation

The package can be installed by adding `crux_gateway` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:crux_gateway, "~> 0.1.1"}
  ]
end
```

## Usage

For example:

```elixir
  iex> Crux.Gateway.start(%{
  ...>   token: "your token goes, for example, here",
  ...>   url: "wss://discord.gg",
  ...>   shard_count: 1
  ...> })
  [ok: #PID<0.187.0>]
```