defmodule CloudDelta.MixProject do
  use Mix.Project

  def project do
    [
      app: :cloud_delta,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: [{:nx, "~> 0.5"}],
      description: "High-performance 2D point cloud compression library using delta encoding and Huffman compression.",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/doctorcorral/point_cloud_compression"}
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {CloudDelta.Application, []}
    ]
  end

end
