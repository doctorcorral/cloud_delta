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

Encode time, 12-bit, median of 3 wall-clock runs (Apple M-series, 4 Sep
2026). CloudDelta time is `compress/2` (quantize + Morton + zlib). Draco
and G-PCC times are the encoder process after the input file is written.
LAZ time is `laspy` write/compress only (no Python startup).

| Dataset | n | CloudDelta | Draco | LAZ | G-PCC | CD / Draco | CD / G-PCC |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bun000 | 40,256 | 40 ms | **11 ms** | 3.6 ms | 42 ms | 3.8× | 0.96× |
| zipper | 35,947 | 36 ms | **11 ms** | 4.2 ms | 44 ms | 3.4× | 0.83× |
| armadillo | 172,974 | 258 ms | **46 ms** | 9.1 ms | 158 ms | 5.6× | 1.6× |
| KITTI | 125,635 | 193 ms | **30 ms** | 8.3 ms | 84 ms | 6.4× | 2.3× |
| Autzen | 110,000 | 177 ms | **26 ms** | 6.4 ms | 100 ms | 6.8× | 1.8× |

Elixir vs C++ is most of the Draco gap. Against the G-PCC reference encoder
the gap is small on the Stanford scans and about 2× on LiDAR. LAZ is in
another speed class. Lossless CloudDelta is 2–5× slower than zlib and
~10–20× slower than zstd; that is the cost of the spatial pass.

Decode time, 12-bit, same method (`uncompress_points/1`, `draco_decoder`,
laspy read, `tmc3 --mode=1`):

| Dataset | CloudDelta | Draco | LAZ | G-PCC | CD / Draco | CD / G-PCC |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| bun000 | 15 ms | **5.5 ms** | 4.5 ms | 51 ms | 2.8× | **0.30×** |
| zipper | 14 ms | **4.8 ms** | 5.7 ms | 50 ms | 2.8× | **0.28×** |
| armadillo | 84 ms | **14 ms** | 9.7 ms | 201 ms | 6.2× | **0.42×** |
| KITTI | 64 ms | **10 ms** | 7.3 ms | 131 ms | 6.2× | **0.49×** |
| Autzen | 61 ms | **8.8 ms** | 7.0 ms | 127 ms | 7.0× | **0.48×** |

Decode is CloudDelta’s better number: about 3× faster than its own encode,
and **2–3.5× faster than G-PCC decode** on every set. Still 3–7× behind
Draco, and LAZ remains the speed class of its own. Encode pays the Morton
sort; decode is zlib inflate plus a prefix-sum walk.

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
    {:cloud_delta, "~> 0.2.0"}
  ]
end
```

## License

MIT
