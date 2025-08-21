defmodule CloudDelta.MixProject do
  use Mix.Project

  def project do
    [
      app: :cloud_delta,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "High-performance 2D point cloud compression library using delta encoding and Huffman compression.",
      source_url: "https://github.com/doctorcorral/clouddelta/",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/doctorcorral/clouddelta/"}
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

  defp deps() do
    [
      {:nx, "~> 0.5"}
      {:ex_doc, "~> 0.14", only: :dev, runtime: false}
    ]
  end

end
