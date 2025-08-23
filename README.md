# CloudDelta

An Elixir library for compressing 2D point clouds using delta encoding and Huffman compression.

## Features

- **Dual compression methods**: Hybrid (fast) and Huffman (high compression)
- **Theoretical compression**: Up to 7.99:1 (n = 10,000,000, random pattern)
- **Practical compression**: 3.24-3.68:1 (n = 10,000) with hybrid binary I/O
- **Pattern support**: :squared, :sin, :linear, :random
- **Lossless compression**: Bit-identical reconstruction guaranteed
- **Benchmarking tools**: Side-by-side method comparison
- **Backward compatible**: v1.0 format supported

## Compression Methods

### Huffman (Default) - v1.0 Compatible
- Uses variable-length encoding based on delta frequency
- Better compression ratios on larger datasets
- Slower compression/decompression
- Default method for backward compatibility

### Hybrid - v2.0 Enhancement  
- Stores deltas as raw 32-bit floats
- Faster compression/decompression
- Larger file sizes but better performance
- Useful for real-time applications

## Usage

### Basic Compression

```elixir
# Generate or load point cloud data
{x, y} = CloudDelta.Benchmark.generate_dataset(10_000, :squared)

# Default Huffman compression (v1.0 compatible)
compressed = CloudDelta.compress({x, y})
{x_restored, y_restored} = CloudDelta.uncompress(compressed)

# Verify lossless reconstruction
is_perfect = CloudDelta.check_compression({x, y})
```

### Method Selection

```elixir
# Hybrid method (faster, larger)
compressed_hybrid = CloudDelta.compress({x, y}, method: :hybrid)

# Huffman method (slower, smaller) 
compressed_huffman = CloudDelta.compress({x, y}, method: :huffman)

# Check compression with specific method
is_lossless = CloudDelta.check_compression({x, y}, method: :hybrid)
```

### Benchmarking

```elixir
# Compare methods side-by-side
{x, y} = CloudDelta.Benchmark.generate_dataset(100_000, :random)
results = CloudDelta.Bench.compare_methods({x, y})

# Comprehensive comparison across patterns and sizes
CloudDelta.Bench.comprehensive_comparison()

# Quick benchmark for single pattern
CloudDelta.Bench.comprehensive_comparison([:squared], [1_000, 10_000, 100_000])
```

Example output:
```
=== COMPRESSION METHOD COMPARISON ===
Dataset size: 100000 points
Original size: 3200000 bits (4.0e5 bytes)

=== RESULTS COMPARISON ===
| Method   | Ratio   | Compression | Size (bytes) | Time (ms) | Lossless |
|----------|---------|-------------|--------------|-----------|----------|
| Hybrid   |    4.00 |       75.0% |      100017 |     12.5 |     true |
| Huffman  |    6.50 |       84.6% |       61538 |     89.2 |     true |

=== ANALYSIS ===
Huffman vs Hybrid compression:
- Compression ratio: 1.63x better
- Time overhead: 7.14x slower
- Recommendation: Use Huffman for better compression
```

## Installation

The package can be installed by adding `cloud_delta` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:cloud_delta, "~> 0.1.0"}
  ]
end
```

## Performance

Compression ratios by dataset size (Huffman method):
- n=1,000: ~2.2:1 (54% compression)
- n=10,000: ~3.5:1 (71% compression)  
- n=100,000: ~6.3:1 (84% compression)
- n=1,000,000: ~7.8:1 (87% compression)

## Architecture

CloudDelta uses a multi-stage compression pipeline:

1. **Independent Sorting**: X and Y coordinates are sorted separately with permutation tracking
2. **Delta Encoding**: Compute first differences of sorted arrays
3. **Method Selection**:
   - **Hybrid**: Store deltas as 32-bit floats (4 bytes each)
   - **Huffman**: Build frequency tree and encode with variable-length codes
4. **Binary Serialization**: Combine initial values, permutations, and encoded deltas

## API Reference

### Core Functions

- `CloudDelta.compress({x, y}, opts \\ [])` - Compress point cloud data
- `CloudDelta.uncompress(binary)` - Decompress binary back to {x, y}
- `CloudDelta.check_compression({x, y}, opts \\ [])` - Verify lossless reconstruction

### Benchmarking

- `CloudDelta.Bench.compare_methods({x, y}, opts \\ [])` - Compare compression methods
- `CloudDelta.Bench.comprehensive_comparison(patterns, sizes)` - Full benchmark suite

### Data Generation (for testing)

- `CloudDelta.Benchmark.generate_dataset(n, pattern)` - Generate synthetic data
- `CloudDelta.Benchmark.verify_compression(n, pattern)` - Analyze compression performance

## Notes

- **Backward Compatibility**: The default `:huffman` method maintains compatibility with v1.0
- **Binary Format**: v2.0 adds a method flag byte for format detection
- **Performance**: Hybrid method is ~7x faster but produces ~1.6x larger files
- **Lossless**: Both methods guarantee bit-identical reconstruction

## Documentation

- [Paper](doc/cloud_delta_paper.pdf) - Detailed algorithm description
- [API Docs](https://hexdocs.pm/cloud_delta) - Complete function reference

## Links

- [GitHub](https://github.com/doctorcorral/cloud_delta/)
- [Hex.pm](https://hex.pm/packages/cloud_delta)

## License

MIT - see LICENSE file.
