defmodule Crux.Gateway.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Crux.Gateway.RateLimiter
  alias :timer, as: Timer

  alias Crux.Gateway.Registry

  @name __MODULE__

  setup do
    start_supervised!({Elixir.Registry, name: Registry.name(@name), keys: :unique})

    :ok
  end

  setup context do
    pid =
      case context[:type] do
        :identify ->
          opts = %{
            type: :identify,
            name: @name,
            max_concurrency: context[:max_concurrency] || 1
          }

          start_supervised!({RateLimiter, opts})

        :command ->
          opts = %{
            type: :command,
            name: @name,
            shard_id: 0,
            shard_count: 1
          }

          start_supervised!({RateLimiter, opts})
      end

    [pid: pid]
  end

  describe "identify" do
    @describetag type: :identify

    test "properly registers process", %{pid: pid} do
      assert pid == Process.whereis(Registry.identify_limiter_name(@name))
    end

    test "enqueueing works, the first request is not limited" do
      {timeout, return} = Timer.tc(fn -> RateLimiter.enqueue_identify(%{name: @name}) end)
      assert return == :ok
      assert timeout < 500
    end

    test "multiple requests are being throttled and enqueued" do
      {timeout, return} = Timer.tc(fn -> RateLimiter.enqueue_identify(%{name: @name}) end)
      assert return == :ok
      assert timeout < 500

      task1 =
        Task.async(fn ->
          assert :ok ==
                   assert_throttled(5_000, fn ->
                     RateLimiter.enqueue_identify(%{name: @name})
                   end)
        end)

      task2 =
        Task.async(fn ->
          assert :ok ==
                   assert_throttled(10_000, fn ->
                     RateLimiter.enqueue_identify(%{name: @name})
                   end)
        end)

      Task.await(task1, 5_500)
      Task.await(task2, 10_500)
    end

    @tag max_concurrency: 5
    test "max_concurrency works" do
      {timeout, return} = Timer.tc(fn -> RateLimiter.enqueue_identify(%{name: @name}) end)
      assert return == :ok
      assert timeout < 500

      {timeout, return} = Timer.tc(fn -> RateLimiter.enqueue_identify(%{name: @name}) end)
      assert return == :ok
      assert timeout < 500

      {timeout, return} = Timer.tc(fn -> RateLimiter.enqueue_identify(%{name: @name}) end)
      assert return == :ok
      assert timeout < 500

      {timeout, return} = Timer.tc(fn -> RateLimiter.enqueue_identify(%{name: @name}) end)
      assert return == :ok
      assert timeout < 500

      {timeout, return} = Timer.tc(fn -> RateLimiter.enqueue_identify(%{name: @name}) end)
      assert return == :ok
      assert timeout < 500

      assert :ok ==
               assert_throttled(5000, fn ->
                 RateLimiter.enqueue_identify(%{name: @name})
               end)
    end
  end

  describe "command" do
    @describetag type: :command

    test "properly registers process", %{pid: pid} do
      assert pid == Registry.lookup_command(Registry.name(@name), 0, 1)
    end

    test "emptying command bucket works without being throttled" do
      for _ <- 1..110 do
        {timeout, return} =
          Timer.tc(fn ->
            RateLimiter.enqueue_command(@name, 0, 1)
          end)

        assert return == :ok
        assert timeout < 500
      end
    end
  end

  # https://stackoverflow.com/a/28746505/10602948
  defp assert_throttled(timeout, fun) do
    task = Task.async(fun)
    ref = Process.monitor(task.pid)
    refute_receive {:DOWN, ^ref, :process, _, :normal}, timeout
    Task.await(task)
  end
end
