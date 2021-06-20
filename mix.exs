defmodule Crux.Gateway.MixProject do
  use Mix.Project

  @vsn "0.3.0-dev"
  @name :crux_gateway

  def project do
    [
      start_permanent: Mix.env() == :prod,
      package: package(),
      app: @name,
      version: @vsn,
      elixir: "~> 1.10",
      description: "Package providing a flexible gateway connection to the Discord API.",
      source_url: "https://github.com/SpaceEEC/#{@name}/",
      homepage_url: "https://github.com/SpaceEEC/#{@name}/",
      deps: deps(),
      docs: docs(),
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
        "Documentation" => "https://hexdocs.pm/#{@name}/"
      }
    ]
  end

  def application do
    [extra_applications: [:logger, :inets]]
  end

  defp deps do
    [
      {:gen_stage, "~> 1.0"},
      {:gun, "~> 1.3"},
      {:jason, "~> 1.2", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.23", only: [:dev], runtime: false},
      {:credo, "~> 1.5", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs() do
    [
      formatter: "html",
      extras: [
        "pages/EXAMPLES.md"
      ]
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
