# CloudDelta
An Elixir library for compressing 2D point clouds using delta encoding.
- Theoretical compression: Up to 7.99:1 (n = 10,000,000, random pattern).
- Practical compression: 3.24-3.68:1 (n = 10,000) with hybrid binary I/O.
- Supports patterns: :squared, :sin, :linear, :random.
- Usage: `CloudDelta.compress({x, y})`.
- Docs: [Paper](docs/cloud_delta_paper.pdf)
- Links: [GitHub](https://github.com/doctorcorral/cloud_delta/), [Hex.pm](https://hex.pm/packages/cloud_delta)
- License: MIT - see LICENSE.
- TODO: Full Huffman encoding.

## Installation

The package can be installed
by adding `cloud_delta` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:cloud_delta, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/cloud_delta>.

