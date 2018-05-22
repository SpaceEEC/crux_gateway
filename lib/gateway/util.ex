defmodule Crux.Gateway.Util do
  @moduledoc """
    Collection of util functions.

    Both functions are identical to the ones in `Crux.Structs.Util`.
  """

  @doc """
    Converts a string to an atom.

    Returns an already converted atom as is instead of raising an error.
  """
  @spec string_to_atom(string :: String.t() | atom()) :: atom()
  def string_to_atom(atom) when is_atom(atom), do: atom
  def string_to_atom(string) when is_bitstring(string), do: String.to_atom(string)

  @doc """
    Atomifies all keys in a passed list or map to avoid the mess of mixed string and atom keys the gateway sends.
  """
  @spec atomify(input :: struct() | map() | list()) :: map() | list()
  def atomify(%{__struct__: _struct} = struct), do: struct |> Map.from_struct() |> atomify()
  def atomify(%{} = map), do: Map.new(map, &atomify_kv/1)
  def atomify(list) when is_list(list), do: Enum.map(list, &atomify/1)
  def atomify(other), do: other

  defp atomify_kv({k, v}), do: {string_to_atom(k), atomify(v)}
end
