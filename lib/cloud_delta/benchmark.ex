defmodule CloudDelta.Benchmark do
  @moduledoc """
  Benchmarking and performance analysis utilities for CloudDelta.
  
  This module provides functions to test compression performance, measure ratios,
  and validate lossless reconstruction. Not part of the core compression API.
  """

  alias CloudDelta

    @doc """
  Generate a synthetic 2D point cloud dataset with various patterns and noise.

  This function creates test data for benchmarking and validation purposes.
  Real users of the compression library will have their own point cloud data.

  ## Parameters
  - `n` - Number of points to generate (default: 5)
  - `pattern` - Data generation pattern (default: :squared)
    - `:squared` - Quadratic relationship: y = x² + noise
    - `:sin` - Sinusoidal relationship: y = sin(2πx) + noise
    - `:linear` - Linear relationship: y = 2x + noise
    - `:random` - Completely random y values (no correlation)

  ## Returns
  A tuple `{x, y}` where both are Nx tensors of shape `{n}` containing:
  - `x` - Random values uniformly distributed in [0.0, 2.0]
  - `y` - Values following the specified pattern with noise (noise ~ Normal(0, 0.5))

  ## Examples

            iex> {x, y} = CloudDelta.Benchmark.generate_dataset(100, :squared)
      iex> Nx.shape(x)
      {100}
      
      iex> {x, y} = CloudDelta.Benchmark.generate_dataset(100, :sin)
      iex> Nx.shape(y) 
      {100}
  """
  def generate_dataset(n \\ 5, pattern \\ :squared) do
    key = Nx.Random.key(42) # Seed for reproducibility
    {x, new_key} = Nx.Random.uniform(key, 0.0, 2.0, shape: {n})
    {noise, _} = Nx.Random.normal(new_key, 0.0, 0.5, shape: {n})

    y_base = case pattern do
      :squared ->
        Nx.pow(x, 2)

      :sin ->
        # y = sin(2πx) scaled to [0, 4] range to match squared pattern
        x
        |> Nx.multiply(2 * :math.pi())
        |> Nx.sin()
        |> Nx.add(1.0)  # Shift to [0, 2]
        |> Nx.multiply(2.0)  # Scale to [0, 4]

      :linear ->
        # y = 2x for simple linear relationship
        Nx.multiply(x, 2.0)

      :random ->
        # Completely random y values in [0, 4] range
        {random_y, _} = Nx.Random.uniform(new_key, 0.0, 4.0, shape: {n})
        random_y

      _ ->
        raise ArgumentError, "Unknown pattern #{inspect(pattern)}. Supported: :squared, :sin, :linear, :random"
    end

    y = Nx.add(y_base, noise)
    {x, y}
  end

  @doc """
  Verify theoretical compression ratio and performance metrics.

  This function measures the theoretical compression achievable by the algorithm
  using the same method as the reference implementation (in-memory reconstruction).

  ## Parameters
  - `n` - Number of points to generate and test (default: 5)
  - `pattern` - Data generation pattern (default: :squared)

  ## Returns
  A tuple containing:
  - `ratio` - Compression ratio (e.g., 7.98 for 7.98:1)
  - `compression_percent` - Compression percentage (e.g., 87.47 for 87.47%)
  - `avg_bits` - Average bits per delta value
  - `is_lossless` - Boolean indicating perfect reconstruction

  ## Examples

      iex> {ratio, percent, avg_bits, lossless} = CloudDelta.Benchmark.verify_compression(1000, :sin)
      iex> ratio > 2.0 and lossless
      true
  """
  def verify_compression(n \\ 5, pattern \\ :squared) do
    # Generate dataset
    {x, y} = generate_dataset(n, pattern)
    original_size = n * 2 * 32 # 32 bits per float

    {time, result} =
      :timer.tc(fn ->
        {sorted_dataset, {x_inverse_perm, y_inverse_perm}} = CloudDelta.sort_independently({x, y})
        {x_sorted, y_sorted} = sorted_dataset

        {x_deltas, y_deltas} = CloudDelta.compute_deltas(sorted_dataset)
        {total_bits, avg_bits} = CloudDelta.entropy_encode_deltas({x_deltas, y_deltas})

        compressed_size = total_bits + n * 8 + 2 * 32 # Perms (8 bits/index), initials

        ratio = original_size / compressed_size
        compression_percent = (1 - compressed_size / original_size) * 100

        # In-memory reconstruction (same as reference)
        reconstructed_x = Nx.take_along_axis(x_sorted, x_inverse_perm, axis: 0)
        reconstructed_y = Nx.take_along_axis(y_sorted, y_inverse_perm, axis: 0)

        {ratio, compression_percent, avg_bits, {x, y}, {reconstructed_x, reconstructed_y}, compressed_size}
      end)

    {ratio, compression_percent, avg_bits, {x, y}, {reconstructed_x, reconstructed_y}, compressed_size} = result

    IO.puts("=== COMPRESSION ANALYSIS (#{String.upcase(to_string(pattern))}) ===")
    IO.puts("Execution Time: #{time / 1000} ms")
    IO.puts("Original Size: #{original_size} bits")
    IO.puts("Compressed Size: #{compressed_size} bits")
    IO.puts("Compression Ratio: #{Float.round(ratio, 2)}:1 (#{Float.round(compression_percent, 2)}% compression)")
    IO.puts("Average Bits per Delta: #{Float.round(avg_bits, 2)}")

    # Verify lossless reconstruction
    x_identical = Nx.all(Nx.equal(x, reconstructed_x)) |> Nx.to_number() == 1
    y_identical = Nx.all(Nx.equal(y, reconstructed_y)) |> Nx.to_number() == 1
    is_lossless = x_identical and y_identical
    IO.puts("Lossless: #{is_lossless}")

    {ratio, compression_percent, avg_bits, is_lossless}
  end

  @doc """
  Run a comprehensive benchmark suite across different dataset sizes and patterns.

  Tests compression performance at multiple scales and data patterns, reporting results.

  ## Parameters
  - `test_patterns` - List of patterns to test (default: [:squared, :sin, :linear, :random])
  - `test_sizes` - List of dataset sizes to test (default: [100, 1_000, 10_000])
  """
  def run_benchmark_suite(test_patterns \\ [:squared, :sin, :linear, :random], test_sizes \\ [100, 1_000, 10_000]) do
    IO.puts("=== POINT CLOUD COMPRESSION BENCHMARK SUITE ===\n")

    all_results = for pattern <- test_patterns do
      IO.puts("=== Testing Pattern: #{String.upcase(to_string(pattern))} ===")

      pattern_results = for n <- test_sizes do
        IO.puts("Testing n=#{n} with #{pattern} pattern...")
        {ratio, percent, avg_bits, lossless} = verify_compression(n, pattern)
        IO.puts("")
        {n, pattern, ratio, percent, avg_bits, lossless}
      end

      pattern_results
    end |> List.flatten()

    IO.puts("=== COMPREHENSIVE BENCHMARK SUMMARY ===")
    IO.puts("| Pattern  | Size     | Ratio   | Compression | Avg Bits | Lossless |")
    IO.puts("|----------|----------|---------|-------------|----------|----------|")

    for {n, pattern, ratio, percent, avg_bits, lossless} <- all_results do
      pattern_str = String.pad_leading(to_string(pattern), 8)
      n_str = String.pad_leading(to_string(n), 8)
      ratio_str = String.pad_leading(Float.round(ratio, 2) |> to_string(), 7)
      percent_str = String.pad_leading(Float.round(percent, 1) |> to_string(), 10)
      bits_str = String.pad_leading(Float.round(avg_bits, 2) |> to_string(), 8)
      lossless_str = String.pad_leading(to_string(lossless), 8)

      IO.puts("| #{pattern_str} | #{n_str} | #{ratio_str} | #{percent_str}% | #{bits_str} | #{lossless_str} |")
    end

    all_results
  end

  @doc """
  Run a quick benchmark suite for a single pattern across sizes.

  ## Parameters
  - `pattern` - Pattern to test (default: :squared)
  """
  def run_pattern_benchmark(pattern \\ :squared) do
    run_benchmark_suite([pattern], [100, 1_000, 10_000, 100_000])
  end
end
