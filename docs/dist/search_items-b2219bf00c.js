searchNodes=[{"doc":"Main entry point for Crux.Gateway.This module fits under a supervision tree, see start_link/1 for configuration options.","ref":"Crux.Gateway.html","title":"Crux.Gateway","type":"module"},{"doc":"Returns a specification to start this module under a supervisor.See Supervisor.","ref":"Crux.Gateway.html#child_spec/1","title":"Crux.Gateway.child_spec/1","type":"function"},{"doc":"A map of all running GenStage producers.See event/0 for the type of published event.","ref":"Crux.Gateway.html#producers/1","title":"Crux.Gateway.producers/1","type":"function"},{"doc":"Send a command to Discord through the specified shard.Errors::not_ready - The connection is currently not ready, try again later.:too_large - The given command was too large. (You shouldn't exceed this, the payload likely is invalid anyway.):not_found - The connection process for the given shard tuple wasn't found. (This means that there is no process with that id and count. Or it just crashed, which shouldn't happen.):no_rate_limiter - The connection was found, but its rate limiter wasn't. (This means it crashed, that shouldn't happen.)","ref":"Crux.Gateway.html#send_command/3","title":"Crux.Gateway.send_command/3","type":"function"},{"doc":"A map of all running shard supervisors.","ref":"Crux.Gateway.html#shards/1","title":"Crux.Gateway.shards/1","type":"function"},{"doc":"Start this module linked to the current process, intended to be used in combination with a Supervisor.","ref":"Crux.Gateway.html#start_link/1","title":"Crux.Gateway.start_link/1","type":"function"},{"doc":"Start a shard.","ref":"Crux.Gateway.html#start_shard/2","title":"Crux.Gateway.start_shard/2","type":"function"},{"doc":"Stop a shard.","ref":"Crux.Gateway.html#stop_shard/2","title":"Crux.Gateway.stop_shard/2","type":"function"},{"doc":"Type for events published by Crux.Gateway's shard gen stage stages.For example: {:MESSAGE_CREATE, %{...}, {0, 1}}","ref":"Crux.Gateway.html#t:event/0","title":"Crux.Gateway.event/0","type":"type"},{"doc":"The given name for a Crux.Gateway process.","ref":"Crux.Gateway.html#t:gateway/0","title":"Crux.Gateway.gateway/0","type":"type"},{"doc":"Required to start Crux.Gateway.These can optionally be a function for lazy loading, said function is applied exactly once with no arguments when the process is started.Required:name - The name to use for the Crux.Gateway process.:token - The bot token to use, you can get the one of your bot from here.:url - The gateway URL to connect to (must use the wss protocol), obtained from GET /gateway/bot. (See also c:Crux.Rest.get_gateway_bot/0)Optional:intents - The types of events you would like to receive from Discord. (See also Crux.Structs.Intents)If none are provided here, you must provide them when starting a shard.:shards - Initial shards to launch on startup.:presence - Used as initial presence for every session. (See also presence/0)Defaults to none (the bot will be online with no activity):max_concurrency - How many shards may identify within 5 seconds, obtained from /gateway/bot (See also c:Crux.Rest.get_gateway_bot/0)Defaults to 1:dispatcher - An atom representing a dispatcher module or a tuple of one and inital options.Defaults to GenStage.DemandDispatcher.","ref":"Crux.Gateway.html#t:opts/0","title":"Crux.Gateway.opts/0","type":"type"},{"doc":"See opts/0.","ref":"Crux.Gateway.html#t:opts_map/0","title":"Crux.Gateway.opts_map/0","type":"type"},{"doc":"Used as initial presence for every session. Can be either a map representing the presence to use or a function taking the shard id and the shard count and returning a presence map to use.","ref":"Crux.Gateway.html#t:presence/0","title":"Crux.Gateway.presence/0","type":"type"},{"doc":"See presence/0.","ref":"Crux.Gateway.html#t:presence_map/0","title":"Crux.Gateway.presence_map/0","type":"type"},{"doc":"The shard count of a shard, shards are identified by a tuple of shard id and shard count.","ref":"Crux.Gateway.html#t:shard_count/0","title":"Crux.Gateway.shard_count/0","type":"type"},{"doc":"The id of a shard, shards are identified by a tuple of shard id and shard count.","ref":"Crux.Gateway.html#t:shard_id/0","title":"Crux.Gateway.shard_id/0","type":"type"},{"doc":"Used to start a shard.Required:shard_id - The id of the shard you want to start.shard_count - The shard count of the shard you want to start.:intents - What kind of events you would like to receive. (See also Crux.Structs.Intents)Optional when specified in opts/0, if specified here anyway, this value will override the former.Optional:intents - What events you would like to receive from Discord. (See also Crux.Structs.Intents)Required when not specified in opts/0, if specified here anyway, this value will override the former.:presence - Used as initial presence for every session. (See also presence/0)If present this will override the presenve provided when starting Crux.Gateway.:session_id - If you want to (try to) resume a disconnected session, this also requires :seq to be set.:seq - If you want to (try to) resume a disconnected session, this also requires :session_id to be set.","ref":"Crux.Gateway.html#t:shard_opts/0","title":"Crux.Gateway.shard_opts/0","type":"type"},{"doc":"A tuple of shard id and shard count used to identify a shard.","ref":"Crux.Gateway.html#t:shard_tuple/0","title":"Crux.Gateway.shard_tuple/0","type":"type"},{"doc":"Builds Gateway Commands. Note: Only the sent ones can be found here.A list of available op codes:OP CodeNameDirection0dispatchreceived only1heartbeattwo way2identifysent only3status_updatesent only4voice_state_updatesent only5Removed / Not for botsneither6resumesent only7reconnectreceived only8request_guild_memberssent only9invalid_sessionreceived only10helloreceived only11heartbeat_ackreceived onlyGateway Lifecycle Flowchart","ref":"Crux.Gateway.Command.html","title":"Crux.Gateway.Command","type":"module"},{"doc":"Encodes the given command map to a term that can be sent using Crux.Gateway.send_command/3.","ref":"Crux.Gateway.Command.html#encode_command/1","title":"Crux.Gateway.Command.encode_command/1","type":"function"},{"doc":"Builds a Heartbeat command.Used to signalize the server that the client is still alive and able to receive messages.Internally handled by Crux.Gateway already.","ref":"Crux.Gateway.Command.html#heartbeat/1","title":"Crux.Gateway.Command.heartbeat/1","type":"function"},{"doc":"Builds an Identify command.Used to identify the gateway connection and &quot;log in&quot;.Internally handled by Crux.Gateway already.","ref":"Crux.Gateway.Command.html#identify/1","title":"Crux.Gateway.Command.identify/1","type":"function"},{"doc":"Builds a Request Guild Members command.Used to request guild member for a specific guild.Note: This must be sent to the connection handling the guild, otherwise the request will just be ignored.The gateway will respond with :GUILD_MEMBERS_CHUNK packets until all (requested) members were received.","ref":"Crux.Gateway.Command.html#request_guild_members/2","title":"Crux.Gateway.Command.request_guild_members/2","type":"function"},{"doc":"Builds a Resume command.Used to resume into a session which was unexpectly disconnected and may be resumable.Internally handled by Crux.Gateway already.","ref":"Crux.Gateway.Command.html#resume/1","title":"Crux.Gateway.Command.resume/1","type":"function"},{"doc":"Builds a Update Status command. Used to update the status of the client, including activity.","ref":"Crux.Gateway.Command.html#update_status/2","title":"Crux.Gateway.Command.update_status/2","type":"function"},{"doc":"Builds a Update Voice State command.Used to join, switch between, and leave voice channels and/or change self_mute or self_deaf states.","ref":"Crux.Gateway.Command.html#update_voice_state/3","title":"Crux.Gateway.Command.update_voice_state/3","type":"function"},{"doc":"Used to set an activity via update_status/2.:type must be a valid Activity TypeNote that streaming requires a twitch url pointing to a possible channel!","ref":"Crux.Gateway.Command.html#t:activity/0","title":"Crux.Gateway.Command.activity/0","type":"type"},{"doc":"Encoded command ready to be sent to the gateway via Crux.Gateway.send_command/3. If you want to build custom commands (read: new commands not yet supported by crux_gateway), build a valid Gateway Payload Structure using string keys(!) and pass it to encode_command/1.","ref":"Crux.Gateway.Command.html#t:command/0","title":"Crux.Gateway.Command.command/0","type":"opaque"}]