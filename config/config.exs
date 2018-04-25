use Mix.Config

# Everything may be set / overriden via `Crux.Gateway.start/1´.
# See documentation of the `Crux.Gateway` module.
# config :crux_gateway,
#    # required
#    token: "your token",
#    # required, fetch via /gateway/bot
#    shard_count: 5,
#    # required, fetch via /gateway(/bot)
#    url: "wss://gateway.discord.gg",
#    # optional
#    shards: [1, 2, 3..5]
#    # optional
#    dispatcher: GenStage.BroadcastDispatcher
