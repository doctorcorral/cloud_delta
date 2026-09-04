# CloudDelta

2D and 3D point-cloud compression in Elixir. A cloud is treated as a **set of
points**: Morton-order, optional quantization, delta encode, zlib.

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

Synthetic 2D, n=10,000:

| Pattern | zlib raw | lossless | 16-bit | 12-bit |
| --- | ---: | ---: | ---: | ---: |
| random | 1.13 | 1.43 | 2.40 | 3.99 |
| clustered | 1.15 | 1.60 | 2.83 | 5.25 |
| grid | 1.30 | 1.65 | 5.05 | 16.16 |

Real 3D (4 Sep 2026). Ratio vs packed f32. Quantized LAZ (laspy/lazrs) and
G-PCC (`tmc3` v23-rc2, octree, geom-only, no angular mode) use the **same
integer grid** as CloudDelta. Draco 1.5.7 uses its own `-qp` on the original
floats.

Lossless (bit-exact float32; LAZ/G-PCC do not apply):

| Dataset | n | zlib | zstd | CloudDelta |
| --- | ---: | ---: | ---: | ---: |
| bun000 range scan | 40,256 | 1.77 | 2.36 | **2.86** |
| bunny zipper | 35,947 | 1.10 | 1.09 | **1.31** |
| armadillo | 172,974 | 1.74 | 1.60 | **1.77** |
| KITTI Velodyne 000000 | 125,635 | 1.56 | 1.35 | **1.81** |
| Autzen ALS trim | 110,000 | 1.97 | 1.93 | **2.66** |

12-bit, encoded bytes. “vs X” is CloudDelta / X (below 1 means we are smaller):

| Dataset | CD | Draco | LAZ | G-PCC | vs Draco | vs LAZ | vs G-PCC |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bun000 | 74,046 | 86,476 | **37,359** | 53,869 | 0.86× | 1.98× | 1.37× |
| zipper | 92,943 | 87,486 | 115,605 | **75,437** | 1.06× | 0.80× | 1.23× |
| armadillo | 353,563 | 330,227 | 692,264 | **238,160** | 1.07× | 0.51× | 1.48× |
| KITTI | 205,679 | **99,678** | 155,907 | 153,702 | 2.06× | 1.32× | 1.34× |
| Autzen | 259,816 | **149,395** | 190,676 | 200,619 | 1.74× | 1.36× | 1.30× |

Morton+delta beats quantize-then-zstd on every cloud. It does not beat G-PCC
on any of these sets, and it loses badly to Draco on LiDAR at 8-bit (KITTI
44,778 B vs Draco 8,437 B). LAZ wins the structured range scan and loses on
dense reconstructions. The method is in the same conversation as the
standards — a different, simpler pipeline — not a replacement for them.

Encode time, 12-bit, median of 5 wall-clock runs (Apple M-series, 4 Sep
2026). CloudDelta is `compress/2` after an Elixir-only hot-path rewrite
(tuples, one-pass bbox, `:lists.sort`, no NIF). The CD2 bitstream is
unchanged. Draco and G-PCC times are the encoder process after the input
file is written. LAZ time is `laspy` write/compress only.

| Dataset | n | CloudDelta | Draco | LAZ | G-PCC | CD / Draco | CD / G-PCC |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bun000 | 40,256 | 18 ms | **11 ms** | 3.6 ms | 42 ms | 1.6× | **0.43×** |
| zipper | 35,947 | 18 ms | **11 ms** | 4.2 ms | 44 ms | 1.6× | **0.41×** |
| armadillo | 172,974 | 100 ms | **46 ms** | 9.1 ms | 158 ms | 2.2× | **0.63×** |
| KITTI | 125,635 | 94 ms | **30 ms** | 8.3 ms | 84 ms | 3.1× | 1.1× |
| Autzen | 110,000 | 97 ms | **26 ms** | 6.4 ms | 100 ms | 3.7× | **0.97×** |

CloudDelta encode is now faster than the G-PCC reference on the Stanford
scans and Autzen, and about even on KITTI. Draco is still 1.6–3.7× ahead
(C++). LAZ is in another speed class.

Decode time, 12-bit, same CloudDelta build (`uncompress_points/1`). Draco /
LAZ / G-PCC decode times are from the earlier tool pass:

| Dataset | CloudDelta | Draco | LAZ | G-PCC | CD / Draco | CD / G-PCC |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| bun000 | 8.4 ms | **5.5 ms** | 4.5 ms | 51 ms | 1.5× | **0.16×** |
| zipper | 15 ms | **4.8 ms** | 5.7 ms | 50 ms | 3.1× | **0.30×** |
| armadillo | 62 ms | **14 ms** | 9.7 ms | 201 ms | 4.4× | **0.31×** |
| KITTI | 30 ms | **10 ms** | 7.3 ms | 131 ms | 3.0× | **0.23×** |
| Autzen | 64 ms | **8.8 ms** | 7.0 ms | 127 ms | 7.3× | **0.51×** |

Decode stays CloudDelta’s better number against G-PCC (2–6× faster). Still
behind Draco and LAZ. Encode pays the Morton sort; decode is zlib inflate
plus a prefix-sum walk.

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

# Real clouds + RD curve + zlib/zstd/Draco/LAZ/G-PCC
CloudDelta.Compare.run()
```

Put Stanford `bunny/` and `Armadillo.ply` under `priv/datasets/` (see
[3D Scanning Repository](http://graphics.stanford.edu/data/3Dscanrep/)).
Optional LiDAR: a KITTI Velodyne `.bin` and/or a LAS/LAZ under
`priv/datasets/lidar/`. LAZ needs `laspy` + `lazrs` (see `.tools/.venv`).
G-PCC needs `tmc3` from MPEG TMC13 (`TMC3` or `.tools/tmc13/build/tmc3/tmc3`).

## Installation

```elixir
def deps do
  [
    {:cloud_delta, "~> 0.2.1"}
  ]
end
```

## License

MIT
