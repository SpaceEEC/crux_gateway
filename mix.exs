defmodule Crux.Gateway.MixProject do
  use Mix.Project

  @vsn "0.2.0-dev"
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
      deps: deps()
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
      {:gen_stage, "~> 0.13.1"},
      {:websockex, "~> 0.4.1"},
      {:poison, "~> 3.1.0"},
      {:credo, "~> 0.9.2", only: [:dev, :test], runtime: false},
      {:ex_doc,
       git: "https://github.com/spaceeec/ex_doc",
       branch: "feat/umbrella",
       only: :dev,
       runtime: false}
    ]
  end
end
