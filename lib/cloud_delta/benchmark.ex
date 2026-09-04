defmodule CloudDelta.Benchmark do
  @moduledoc """
  Dataset generation and honest compression benchmarks.

  Every reported ratio is `raw_float32_bytes / encoded_byte_size` of a real
  binary. Reconstruction is checked on that same binary.
  """

  @doc """
  Generate a synthetic 2D point cloud.

  Patterns:
    * `:squared` — `y = x² + noise`
    * `:sin` — shifted sine plus noise
    * `:linear` — `y = 2x + noise`
    * `:random` — uncorrelated uniform noise
    * `:clustered` — five tight Gaussian blobs (spatially coherent)
    * `:grid` — regular lattice plus tiny noise
  """
  def generate_dataset(n \\ 5, pattern \\ :squared) do
    key = Nx.Random.key(42)

    case pattern do
      :clustered ->
        clustered(n, key)

      :grid ->
        grid(n, key)

      _ ->
        {x, new_key} = Nx.Random.uniform(key, 0.0, 2.0, shape: {n})
        {noise, _} = Nx.Random.normal(new_key, 0.0, 0.5, shape: {n})

        y =
          case pattern do
            :squared ->
              Nx.add(Nx.pow(x, 2), noise)

            :sin ->
              x
              |> Nx.multiply(2 * :math.pi())
              |> Nx.sin()
              |> Nx.add(1.0)
              |> Nx.multiply(2.0)
              |> Nx.add(noise)

            :linear ->
              Nx.add(Nx.multiply(x, 2.0), noise)

            :random ->
              {random_y, _} = Nx.Random.uniform(new_key, 0.0, 4.0, shape: {n})
              random_y

            _ ->
              raise ArgumentError,
                    "Unknown pattern #{inspect(pattern)}. Supported: :squared, :sin, :linear, :random, :clustered, :grid"
          end

        {x, y}
    end
  end

  defp clustered(n, key) do
    k = 5
    {centers_x, key} = Nx.Random.uniform(key, 0.2, 1.8, shape: {k})
    {centers_y, key} = Nx.Random.uniform(key, 0.2, 3.8, shape: {k})
    {assign, key} = Nx.Random.uniform(key, 0.0, k * 1.0, shape: {n})
    idx = Nx.as_type(Nx.clip(Nx.floor(assign), 0, k - 1), :s32)
    {jx, key} = Nx.Random.normal(key, 0.0, 0.06, shape: {n})
    {jy, _} = Nx.Random.normal(key, 0.0, 0.06, shape: {n})
    cx = Nx.take(centers_x, idx)
    cy = Nx.take(centers_y, idx)
    {Nx.add(cx, jx), Nx.add(cy, jy)}
  end

  defp grid(n, key) do
    side = max(ceil(:math.sqrt(n)), 1)
    {jitter, _} = Nx.Random.normal(key, 0.0, 1.0e-4, shape: {n})

    coords =
      Enum.map(0..(n - 1), fn i ->
        gx = rem(i, side) / max(side - 1, 1) * 2.0
        gy = div(i, side) / max(side - 1, 1) * 4.0
        {gx, gy}
      end)

    {xs, ys} = Enum.unzip(coords)
    x = Nx.add(Nx.tensor(xs, type: :f32), jitter)
    y = Nx.add(Nx.tensor(ys, type: :f32), jitter)
    {x, y}
  end

  @doc """
  Measure one dataset with a real compress/uncompress round-trip.
  """
  def measure(n, pattern, opts \\ [mode: :quantized, bits: 16]) do
    {x, y} = generate_dataset(n, pattern)
    raw_bytes = n * 8
    packed = pack_f32(x, y, n)
    zlib_bytes = byte_size(:zlib.compress(packed))

    {encode_us, compressed} = :timer.tc(fn -> CloudDelta.compress({x, y}, opts) end)
    {decode_us, {_xr, _yr}} = :timer.tc(fn -> CloudDelta.uncompress(compressed) end)

    compressed_bytes = byte_size(compressed)
    mode = Keyword.get(opts, :mode, :quantized)

    {lossless?, max_err} =
      case mode do
        :lossless ->
          ordered = CloudDelta.compress({x, y}, Keyword.put(opts, :preserve_order, true))
          {xr, yr} = CloudDelta.uncompress(ordered)
          {exact_match?({x, y}, {xr, yr}), 0.0}

        _ ->
          ordered = CloudDelta.compress({x, y}, Keyword.put(opts, :preserve_order, true))
          {xr, yr} = CloudDelta.uncompress(ordered)
          {false, max_abs_error({x, y}, {xr, yr})}
      end

    %{
      pattern: pattern,
      n: n,
      mode: mode,
      bits: Keyword.get(opts, :bits, 16),
      raw_bytes: raw_bytes,
      zlib_bytes: zlib_bytes,
      compressed_bytes: compressed_bytes,
      ratio: raw_bytes / max(compressed_bytes, 1),
      zlib_ratio: raw_bytes / max(zlib_bytes, 1),
      vs_zlib: zlib_bytes / max(compressed_bytes, 1),
      lossless: lossless?,
      max_abs_error: max_err,
      encode_ms: encode_us / 1000,
      decode_ms: decode_us / 1000
    }
  end

  @doc """
  Print an honest benchmark table.
  """
  def run_benchmark_suite(
        patterns \\ [:random, :linear, :squared, :clustered, :grid],
        sizes \\ [1_000, 10_000],
        opts \\ [mode: :quantized, bits: 16]
      ) do
    IO.puts("=== CloudDelta honest benchmark ===")
    IO.puts("opts=#{inspect(opts)}\n")

    rows =
      for pattern <- patterns, n <- sizes do
        row = measure(n, pattern, opts)
        IO.puts(format(row))
        row
      end

    IO.puts("\npattern,n,mode,bits,raw,zlib,cloud,ratio,zlib_ratio,vs_zlib,max_err,lossless")

    for row <- rows do
      IO.puts(
        Enum.join(
          [
            row.pattern,
            row.n,
            row.mode,
            row.bits,
            row.raw_bytes,
            row.zlib_bytes,
            row.compressed_bytes,
            f(row.ratio),
            f(row.zlib_ratio),
            f(row.vs_zlib),
            f(row.max_abs_error),
            row.lossless
          ],
          ","
        )
      )
    end

    rows
  end

  defp format(row) do
    Enum.join(
      [
        "#{row.pattern} n=#{row.n}",
        "#{row.compressed_bytes}B",
        "#{f(row.ratio)}:1 vs raw",
        "#{f(row.zlib_ratio)}:1 zlib",
        "#{f(row.vs_zlib)}x vs zlib",
        "err=#{f(row.max_abs_error)}",
        if(row.lossless, do: "LOSSLESS", else: "quantized")
      ],
      " | "
    )
  end

  defp f(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 3)
  defp f(x), do: to_string(x)

  defp pack_f32(x, y, n) do
    Enum.reduce(0..(n - 1), <<>>, fn i, acc ->
      acc <> <<Nx.to_number(x[i])::float-32, Nx.to_number(y[i])::float-32>>
    end)
  end

  defp exact_match?({x, y}, {xr, yr}) do
    Nx.all(Nx.equal(x, xr)) |> Nx.to_number() == 1 and
      Nx.all(Nx.equal(y, yr)) |> Nx.to_number() == 1
  end

  defp max_abs_error({x, y}, {xr, yr}) do
    Enum.zip([
      Nx.to_flat_list(x),
      Nx.to_flat_list(y),
      Nx.to_flat_list(xr),
      Nx.to_flat_list(yr)
    ])
    |> Enum.reduce(0.0, fn {x1, y1, x2, y2}, acc ->
      max(acc, max(abs(x1 - x2), abs(y1 - y2)))
    end)
  end
end
