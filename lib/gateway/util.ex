defmodule Crux.Gateway.Util do
  @moduledoc false

  @spec atomify(input :: struct() | map() | list()) :: map() | list()
  def atomify(input)
  def atomify(%{__struct__: _struct} = struct), do: struct |> Map.from_struct() |> atomify()
  def atomify(%{} = map), do: Map.new(map, &atomify_kv/1)
  def atomify(list) when is_list(list), do: Enum.map(list, &atomify/1)
  def atomify(other), do: other

  defp atomify_kv({k, v}) when is_atom(k), do: {k, atomify(v)}
  defp atomify_kv({k, v}) when is_binary(k), do: {String.to_atom(k), atomify(v)}
  defp atomify_kv({k, v}), do: {k, atomify(v)}
end
