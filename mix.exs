defmodule Crux.Gateway.MixProject do
  use Mix.Project

  def project do
    [
      start_permanent: Mix.env() == :prod,
      package: package(),
      app: :crux_gateway,
      version: "0.1.0",
      elixir: "~> 1.6",
      description: "Package providing a flexible gateway connection to the Discord API.",
      source_url: "https://github.com/SpaceEEC/crux_gateway/",
      homepage_url: "https://github.com/SpaceEEC/crux_gateway/",
      deps: deps()
    ]
  end

  def package do
    [
      name: :crux_gateway,
      licenses: ["MIT"],
      maintainers: ["SpaceEEC"],
      links: %{
        "GitHub" => "https://github.com/SpaceEEC/crux_gateway/",
        "Docs" => "https://hexdocs.pm/crux_gateway/"
      }
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Crux.Gateway.Application, []}
    ]
  end

  defp deps do
    [
      {:gen_stage, "~> 0.13.1"},
      {:websockex, "~> 0.4.1"},
      {:poison, "~> 3.1.0"},
      {:credo, "~> 0.9.2", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.18.3", only: :dev}
    ]
  end
end
