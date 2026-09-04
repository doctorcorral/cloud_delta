defmodule CloudDelta.MixProject do
  use Mix.Project

  def project do
    [
      app: :cloud_delta,
      version: "0.2.1",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "2D/3D point-cloud compression: Morton reorder, optional quantization, delta encoding, zlib.",
      source_url: "https://github.com/doctorcorral/cloud_delta",
      docs: [
        main: "readme",
        extras: ["README.md"]
      ],
      package: [
        maintainers: ["Ricardo Corral-Corral"],
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/doctorcorral/cloud_delta"},
        files: ~w(lib scripts/laz_codec.py mix.exs README.md LICENSE)
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {CloudDelta.Application, []}
    ]
  end

  defp deps() do
    [
      {:nx, "~> 0.5"},
      {:ex_doc, "~> 0.14", only: :dev, runtime: false}
    ]
  end
end
