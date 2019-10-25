defmodule Crux.Gateway.CommandTest do
  use ExUnit.Case
  doctest Crux.Gateway.Command

  # Since the commands directly make it WebSocket friendly
  defp unfinalize({:binary, data}) do
    %{"d" => d} = :erlang.binary_to_term(data)

    d
  end

  describe "request_guild_members/1,2" do
    # Get the guild_id out of the way
    def request_guild_members(opts \\ []) do
      Crux.Gateway.Command.request_guild_members(1234, opts)
    end

    # Builds the expected map, including defaults
    defp build_expected(opts) do
      opts = Map.new(opts, fn {k, v} -> {to_string(k), v} end)

      %{"guild_id" => 1234, "limit" => 0, "presences" => false}
      |> Map.merge(opts)
    end

    test "/1" do
      received = request_guild_members() |> unfinalize()
      # The default is all of them
      expected = build_expected(query: "")

      assert received === expected
    end

    test "all options" do
      opts = %{query: "space", limit: 15, user_ids: [1, 2, 3], presences: true}

      received = request_guild_members(opts) |> unfinalize()

      expected = build_expected(query: "space", limit: 15, user_ids: [1, 2, 3], presences: true)

      assert received === expected
    end

    test "query does not return user_ids" do
      opts = [query: "space"]

      received = request_guild_members(opts) |> unfinalize()
      expected = build_expected(query: "space")

      assert received === expected
    end

    test "user_ids does not return query" do
      opts = [user_ids: [1, 2, 3]]

      received = request_guild_members(opts) |> unfinalize()
      expected = build_expected(user_ids: [1, 2, 3])

      assert received === expected
    end
  end
end
