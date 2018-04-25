defmodule Crux.Gateway.Application do
  @moduledoc """
    Root for the supervision tree.
  """
  use Application

  @doc """
  Starts the Gateway Supervision tree.

  This does _NOT_ actually connect to the gateway.
  See `Crux.Gateway.start/1`
  """
  def start(_type, _args), do: Crux.Gateway.Supervisor.start_link()
end
