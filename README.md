# CloudDelta

2D point-cloud compression in Elixir. A point cloud is treated as a **set of
`(x, y)` pairs**: reorder for spatial locality (Morton order), quantize, delta
encode, then entropy-code with zlib.

## Honest status

v0.1 advertised **7.99:1** lossless compression and “0.01 bits/delta”. Those
numbers were not real:

- The published metric summed **unique Huffman code lengths** and counted
  **one 8-bit permutation array**. It never measured the bytes `compress/1`
  wrote, never stored a Huffman tree, and never decoded residuals.
- Independent sorting of X and Y **breaks pairing**. Restoring the original
  points requires two permutations (`2 n log2 n` bits). That cost alone makes
  the old scheme expand on unique float32 data.
- The shipped encoder stored every float again inside a Huffman tree and used
  8-bit indices (broken for `n > 255`). Actual binaries were ~4× **larger**
  than raw float32, and round-trips were not lossless.

This tree replaces that pipeline. Ratios below are `raw_f32_bytes / encoded_bytes`
of a real binary, checked by decompressing it.

## What it does now

| Mode | Reconstruction | When it wins |
| --- | --- | --- |
| `mode: :quantized` (default, 16-bit) | Bounded error, about one quantum | Structured / clustered / gridded clouds |
| `mode: :lossless` | Bit-exact float32 | Near-incompressible unique floats; aims to match or beat `zlib` on the packed points |

Unique random float32s are already near entropy. No lossless codec will turn
those into 8:1. Competence here means: **never lie about size**, **actually
round-trip**, and **beat naive zlib on clouds with spatial structure**.

Measured on this tree, n=10,000, ratio = raw f32 bytes / encoded bytes:

| Pattern | zlib raw | lossless | 16-bit | 12-bit |
| --- | ---: | ---: | ---: | ---: |
| random | 1.13 | 1.43 | 2.40 | 3.99 |
| clustered | 1.15 | 1.60 | 2.83 | 5.25 |
| grid | 1.30 | 1.65 | 5.05 | 16.16 |

## Usage

```elixir
{x, y} = CloudDelta.Benchmark.generate_dataset(10_000, :clustered)

compressed = CloudDelta.compress({x, y}, mode: :quantized, bits: 16)
{x2, y2} = CloudDelta.uncompress(compressed)

lossless = CloudDelta.compress({x, y}, mode: :lossless, preserve_order: true)
true = CloudDelta.check_compression({x, y})

CloudDelta.stats({x, y}, mode: :quantized, bits: 16)
```

Options:

- `:mode` — `:quantized` (default) or `:lossless`
- `:bits` — quantization bits per axis, `4..24` (default `16`)
- `:preserve_order` — restore input order (default `false`)

## Benchmark

```elixir
CloudDelta.Benchmark.run_benchmark_suite()
```

## Installation

```elixir
def deps do
  [
    {:cloud_delta, "~> 0.2.0"}
  ]
end
```

## License

MIT
