defmodule Crux.Gateway.MixProject do
  use Mix.Project

  @vsn "0.2.3"
  @name :crux_gateway

  def project do
    [
      start_permanent: Mix.env() == :prod,
      package: package(),
      app: @name,
      version: @vsn,
      elixir: "~> 1.6",
      description: "Package providing a flexible gateway connection to the Discord API.",
      source_url: "https://github.com/SpaceEEC/#{@name}/",
      homepage_url: "https://github.com/SpaceEEC/#{@name}/",
      deps: deps(),
      aliases: aliases()
    ]
  end

  def package do
    [
      name: @name,
      licenses: ["MIT"],
      maintainers: ["SpaceEEC"],
      links: %{
        "GitHub" => "https://github.com/SpaceEEC/#{@name}/",
        "Changelog" => "https://github.com/SpaceEEC/#{@name}/releases/tag/#{@vsn}/",
        "Documentation" => "https://hexdocs.pm/#{@name}/",
        "Unified Development Documentation" => "https://crux.randomly.space/"
      }
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:gen_stage, "~> 0.14"},
      {:websockex, "~> 0.4"},
      {:jason, "~> 1.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.1", only: [:dev, :test], runtime: false},
      {:ex_doc,
       git: "https://github.com/spaceeec/ex_doc",
       branch: "feat/umbrella",
       only: :dev,
       runtime: false}
    ]
  end

  defp aliases() do
    [
      docs: ["docs", &generate_config/1]
    ]
  end

  def generate_config(_) do
    config =
      System.cmd("git", ["tag"])
      |> elem(0)
      |> String.split("\n")
      |> Enum.slice(0..-2)
      |> Enum.map(&%{"url" => "https://hexdocs.pm/#{@name}/" <> &1, "version" => &1})
      |> Enum.reverse()
      |> Jason.encode!()

    config = "var versionNodes = " <> config

    __ENV__.file
    |> Path.split()
    |> Enum.slice(0..-2)
    |> Kernel.++(["doc", "docs_config.js"])
    |> Enum.join("/")
    |> File.write!(config)

    Mix.Shell.IO.info(~S{Generated "doc/docs_config.js".})
  end
end
