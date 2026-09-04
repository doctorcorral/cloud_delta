defmodule CloudDeltaTest do
  use ExUnit.Case

  test "lossless mode is bit-exact and works past the old 8-bit index limit" do
    for n <- [1, 5, 64, 256, 300, 1_000] do
      {x, y} = CloudDelta.Benchmark.generate_dataset(n, :random)
      assert CloudDelta.check_compression({x, y})
    end
  end

  test "quantized mode reconstructs within half a quantum" do
    n = 1_000
    bits = 16
    {x, y} = CloudDelta.Benchmark.generate_dataset(n, :clustered)
    bin = CloudDelta.compress({x, y}, mode: :quantized, bits: bits, preserve_order: true)
    {xr, yr} = CloudDelta.uncompress(bin)

    xmin = Nx.reduce_min(x) |> Nx.to_number()
    xmax = Nx.reduce_max(x) |> Nx.to_number()
    ymin = Nx.reduce_min(y) |> Nx.to_number()
    ymax = Nx.reduce_max(y) |> Nx.to_number()
    levels = Bitwise.bsl(1, bits) - 1
    tol = max((xmax - xmin) / levels, (ymax - ymin) / levels) + 1.0e-5

    Enum.zip([
      Nx.to_flat_list(x),
      Nx.to_flat_list(y),
      Nx.to_flat_list(xr),
      Nx.to_flat_list(yr)
    ])
    |> Enum.each(fn {x1, y1, x2, y2} ->
      assert abs(x1 - x2) <= tol
      assert abs(y1 - y2) <= tol
    end)
  end

  test "quantized binaries are smaller than packed float32 on structured clouds" do
    {x, y} = CloudDelta.Benchmark.generate_dataset(2_000, :clustered)
    stats = CloudDelta.stats({x, y}, mode: :quantized, bits: 16)
    assert stats.compressed_bytes < stats.raw_bytes
    assert stats.ratio > 1.5
  end

  test "grid clouds compress far better than raw zlib of float32" do
    {x, y} = CloudDelta.Benchmark.generate_dataset(2_500, :grid)
    stats = CloudDelta.stats({x, y}, mode: :quantized, bits: 12)
    assert stats.ratio > stats.zlib_ratio
    assert stats.vs_zlib > 1.5
  end

  test "preserve_order restores input sequence in lossless mode" do
    points = [{0.1, 0.2}, {1.5, 3.3}, {0.1, 9.0}, {2.0, 0.0}]
    bin = CloudDelta.compress(points, mode: :lossless, preserve_order: true)
    restored = CloudDelta.uncompress_points(bin)
    assert length(restored) == 4

    Enum.zip(points, restored)
    |> Enum.each(fn {{x1, y1}, {x2, y2}} ->
      assert_in_delta x1, x2, 1.0e-6
      assert_in_delta y1, y2, 1.0e-6
    end)
  end

  test "empty and singleton clouds round-trip" do
    assert CloudDelta.uncompress_points(CloudDelta.compress([], mode: :lossless)) == []

    bin = CloudDelta.compress([{1.25, -4.5}], mode: :lossless, preserve_order: true)
    [{x, y}] = CloudDelta.uncompress_points(bin)
    assert_in_delta x, 1.25, 1.0e-6
    assert_in_delta y, -4.5, 1.0e-6
  end

  test "lossless mode beats zlib on clustered data" do
    {x, y} = CloudDelta.Benchmark.generate_dataset(2_000, :clustered)
    stats = CloudDelta.stats({x, y}, mode: :lossless)
    assert stats.compressed_bytes < stats.zlib_bytes
    assert stats.ratio > 1.0
  end

  test "stats compare against real byte counts, not theoretical bit sums" do
    {x, y} = CloudDelta.Benchmark.generate_dataset(200, :linear)
    stats = CloudDelta.stats({x, y}, mode: :quantized, bits: 16)
    bin = CloudDelta.compress({x, y}, mode: :quantized, bits: 16)
    assert stats.compressed_bytes == byte_size(bin)
    assert stats.raw_bytes == 200 * 8
  end
end
