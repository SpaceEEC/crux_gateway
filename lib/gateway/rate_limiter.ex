defmodule Crux.Gateway.RateLimiter do
  @moduledoc false

  # Generic ratelimiter.
  # Handles either (I) the command ratelimit or (II) the identify ratelimit.

  ## (I)
  # Handles rate limiting for a gateway connection.
  # https://discord.com/developers/docs/topics/gateway#rate-limiting
  @command_bucket_timeout 60_000
  # Reserve 10 for heartbeats, identifies, and resumes. Playing it safe (or so I hope).
  @command_bucket_limit 120 - 10

  ## (II)
  # Clients are limited by maximum concurrency when identifying.
  # Maximum concurrency is the number of identify requests allowed per 5 seconds.
  # Maximum concurrency can be retrieved from /gateway/bot
  # https://discord.com/developers/docs/topics/gateway#identifying
  @identify_bucket_timeout 5_000

  # States
  @exhausted :exhausted
  @unexhausted :unexhausted
  @full :full

  require Logger

  alias Crux.Gateway.Registry

  alias :gen_statem, as: GenStateM

  @behaviour GenStateM

  def enqueue_identify(%{name: name}) do
    name
    |> Registry.identify_limiter_name()
    |> GenStateM.call(:enqueue)
  end

  def enqueue_command(name, shard_id, shard_count) do
    name
    |> Registry.name()
    |> Registry.lookup_command(shard_id, shard_count)
    |> case do
      :error ->
        {:error, :no_rate_limiter}

      pid when is_pid(pid) ->
        GenStateM.call(pid, :enqueue)
    end
  end

  ### Client API

  @doc false
  def child_spec(opts \\ %{}) do
    opts = Map.new(opts)

    case Map.get(opts, :type) do
      :identify ->
        %{
          id: __MODULE__.Identify,
          start: {__MODULE__, :start_identify_link, [opts]}
        }

      :command ->
        %{
          id: __MODULE__.Command,
          start: {__MODULE__, :start_command_link, [opts]}
        }

      other ->
        raise ArgumentError, """
        Expected :type to be either of :identify or :command.

        Received: #{inspect(other)}
        """
    end
  end

  @doc "Starts a gateway command ratelimiter linked to the current process."
  def start_command_link(%{
        name: name,
        shard_id: shard_id,
        shard_count: shard_count
      }) do
    Logger.metadata(type: :rate_limiter, shard_id: shard_id, shard_count: shard_count)

    Logger.debug(fn -> "Starting command ratelimiter for shard {#{shard_id}, #{shard_count}}." end)

    name =
      name
      |> Registry.name()
      |> Registry.via_command(shard_id, shard_count)

    GenStateM.start_link(
      name,
      __MODULE__,
      %{
        bucket_timeout: @command_bucket_timeout,
        bucket_limit: @command_bucket_limit
      },
      []
    )
  end

  @doc "Starts an identify ratelimiter linked to the current process."
  def start_identify_link(%{
        name: name,
        max_concurrency: max_concurrency
      }) do
    Logger.metadata(type: :rate_limiter, max_concurrency: max_concurrency)

    Logger.debug(fn ->
      "Starting identify ratelimiter with a maximum concurrency of #{max_concurrency}."
    end)

    name = Registry.identify_limiter_name(name)

    GenStateM.start_link(
      {:local, name},
      __MODULE__,
      %{
        bucket_timeout: @identify_bucket_timeout,
        bucket_limit: max_concurrency
      },
      []
    )
  end

  ### Server API

  @impl GenStateM
  def callback_mode(), do: :state_functions

  @impl GenStateM
  def init(%{
        bucket_timeout: bucket_timeout,
        bucket_limit: bucket_limit
      })
      when bucket_limit > 0 and bucket_timeout > 0 do
    data = %{
      bucket_timeout: bucket_timeout,
      bucket_limit: bucket_limit,
      bucket_left: bucket_limit
    }

    {:ok, @full, data}
  end

  # TODO: Maybe return an error?
  # We currently are limited, postpone further actions.
  def exhausted({:call, _from}, _content, %{bucket_left: 0}) do
    {:keep_state_and_data, :postpone}
  end

  # We no longer are limited.
  def exhausted({:timeout, :reset}, :reset, %{bucket_left: 0, bucket_limit: bucket_limit} = data) do
    data = %{data | bucket_left: bucket_limit}
    {:next_state, @full, data}
  end

  # Execute the last action before and therefore empty the bucket.
  def unexhausted({:call, from}, _content, %{bucket_left: 1} = data) do
    data = %{data | bucket_left: 0}
    {:next_state, @exhausted, data, {:reply, from, :ok}}
  end

  # Execute an action, decrement bucket_left.
  def unexhausted({:call, from}, _content, %{bucket_left: bucket_left} = data) do
    data = %{data | bucket_left: bucket_left - 1}
    {:keep_state, data, {:reply, from, :ok}}
  end

  # Our bucket timed out, fill it.
  def unexhausted({:timeout, :reset}, :reset, %{bucket_limit: bucket_limit} = data) do
    data = %{data | bucket_left: bucket_limit}
    {:next_state, @full, data}
  end

  # About to send the first message, set a timeout.
  def full({:call, _from}, _content, %{bucket_timeout: bucket_timeout} = data) do
    actions = [{{:timeout, :reset}, bucket_timeout, :reset}, :postpone]
    {:next_state, @unexhausted, data, actions}
  end
end
