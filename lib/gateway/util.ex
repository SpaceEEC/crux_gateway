defmodule Crux.Gateway.Util do
  @moduledoc false

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

  @doc """
    Gets the pid of a supervised process by id and the supervisor.
  """
  @spec get_pid(sup :: Supervisor.supervisor(), id :: term()) :: pid() | :error
  def get_pid(sup, id) do
    sup
    |> Supervisor.which_children()
    |> Enum.find(fn
      {^id, _pid, _type, _modules} -> true
      _ -> false
    end)
    |> case do
      {^id, pid, _type, _modules} -> pid
      _ -> :error
    end
  end
end
