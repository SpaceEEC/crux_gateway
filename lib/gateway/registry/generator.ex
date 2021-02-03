defmodule Crux.Gateway.Registry.Generator do
  @moduledoc false

  # Generates via_ and lookup_ functions for different types of processes.

  # Yes, I am overdoing it.

  defmacro __using__(_opts) do
    quote do
      require unquote(__MODULE__)
      import unquote(__MODULE__)

      @spec _lookup(atom(), term()) :: pid() | :error
      def _lookup(registry, key) do
        case Registry.lookup(registry, key) do
          [{pid, _value}] when is_pid(pid) ->
            if Process.alive?(pid) do
              pid
            else
              :error
            end

          [] ->
            :error
        end
      end
    end
  end

  @doc ~S"""
  Defines two functions:
  - `via_` to register a process using this name
  - `lookup_` to lookup a process using this name

  ### Examples

  ```elixir
  registered_name :identify
  # results in...
  def via_identify(registry), do: {:via, Elixir.Registry, {registry, {:identify}}}
  def lookup_identify(registry), do: _lookup(registry, {:identify})

  registered_name :connection, [:shard_id, :shard_count]
  # results in...
  def via_connection(registry, shard_id, shard_count) do
    {:via, Elixir.Registry, {registry, {:connection, shard_id, shard_count}}}
  end

  def lookup_connection(registry, shard_id, shard_count) do
    _lookup(registry, {:connection, shard_id, shard_count})
  end
  ```

  """
  defmacro registered_name(name, args \\ []) do
    args = Enum.map(args, &Macro.var(&1, nil))

    quote do
      @doc """
      Return a :via tuple to register a #{unquote(name)} process.
      """
      def unquote(String.to_atom("via_" <> to_string(name)))(registry, unquote_splicing(args)) do
        key = {unquote(name), unquote_splicing(args)}

        {:via, Elixir.Registry, {registry, key}}
      end

      @doc """
      Lookup a #{unquote(name)} process.
      """
      def unquote(String.to_atom("lookup_" <> to_string(name)))(registry, unquote_splicing(args)) do
        key = {unquote(name), unquote_splicing(args)}

        _lookup(registry, key)
      end
    end
  end
end
