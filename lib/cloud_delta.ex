defmodule CloudDelta do
  @moduledoc """
  Lossless and quantized compression for 2D point sets.

  CloudDelta treats a point cloud as an unordered set of `(x, y)` pairs. It
  reorders those pairs for spatial locality (Morton order), delta-encodes the
  integer coordinates, and entropy-codes the residuals with zlib (DEFLATE).

  The previous independent-axis sort plus “theoretical Huffman” numbers in
  v0.1 were not a working compressor: they discarded pairing, under-counted
  permutation bits, and never measured the bytes actually written. This
  implementation measures real binaries and reconstructs either bit-exact
  floats (`mode: :lossless`) or quantized coordinates (`mode: :quantized`).

  ## Usage

      {x, y} = CloudDelta.Benchmark.generate_dataset(10_000, :clustered)
      compressed = CloudDelta.compress({x, y}, mode: :quantized, bits: 16)
      {x2, y2} = CloudDelta.uncompress(compressed)

      lossless = CloudDelta.compress({x, y}, mode: :lossless)
      true = CloudDelta.check_compression({x, y})
  """

  alias CloudDelta.Codec

  @type points_tensor :: {Nx.Tensor.t(), Nx.Tensor.t()}
  @type point_list :: [{number(), number()}]
  @type compress_opt ::
          {:mode, :quantized | :lossless}
          | {:bits, pos_integer()}
          | {:preserve_order, boolean()}

  @doc """
  Compress a 2D point cloud.

  Accepts `{x, y}` Nx tensors or a list of `{x, y}` tuples.

  Options:
    * `:mode` — `:quantized` (default) or `:lossless`
    * `:bits` — quantization bits per axis in quantized mode, 4..24 (default 16)
    * `:preserve_order` — keep input order (default false; point-set semantics)
  """
  @spec compress(points_tensor() | point_list(), [compress_opt()]) :: binary()
  def compress(points, opts \\ [])

  def compress({x, y}, opts) do
    Codec.encode(to_points(x, y), opts)
  end

  def compress(points, opts) when is_list(points) do
    Codec.encode(points, opts)
  end

  @doc """
  Decompress a CloudDelta binary to `{x, y}` float32 tensors.
  """
  @spec uncompress(binary()) :: points_tensor()
  def uncompress(binary) when is_binary(binary) do
    {xs, ys} = Codec.decode(binary)
    {Nx.tensor(xs, type: :f32), Nx.tensor(ys, type: :f32)}
  end

  @doc """
  Decompress to a list of `{x, y}` floats.
  """
  @spec uncompress_points(binary()) :: point_list()
  def uncompress_points(binary) when is_binary(binary) do
    {xs, ys} = Codec.decode(binary)
    Enum.zip(xs, ys)
  end

  @doc """
  Bit-exact round-trip using lossless mode.
  """
  @spec check_compression(points_tensor() | point_list()) :: boolean()
  def check_compression(points) do
    original = normalize_points(points)
    restored = uncompress_points(compress(points, mode: :lossless, preserve_order: true))

    length(original) == length(restored) and
      Enum.zip(original, restored)
      |> Enum.all?(fn {{x1, y1}, {x2, y2}} ->
        eq32(x1, x2) and eq32(y1, y2)
      end)
  end

  @doc """
  Honest size statistics against packed float32 and zlib-on-raw-float32.
  """
  @spec stats(points_tensor() | point_list(), [compress_opt()]) :: map()
  def stats(points, opts \\ []) do
    list = normalize_points(points)
    n = length(list)
    raw_bytes = n * 8
    packed = pack_f32(list)
    zlib_bytes = byte_size(:zlib.compress(packed))
    compressed = compress(list, opts)
    compressed_bytes = byte_size(compressed)

    %{
      n: n,
      raw_bytes: raw_bytes,
      zlib_bytes: zlib_bytes,
      compressed_bytes: compressed_bytes,
      ratio: ratio(raw_bytes, compressed_bytes),
      zlib_ratio: ratio(raw_bytes, zlib_bytes),
      vs_zlib: ratio(zlib_bytes, compressed_bytes)
    }
  end

  @doc false
  def to_points(%Nx.Tensor{} = x, %Nx.Tensor{} = y) do
    Enum.zip(Nx.to_flat_list(x), Nx.to_flat_list(y))
  end

  defp normalize_points({x, y}), do: to_points(x, y)
  defp normalize_points(points) when is_list(points), do: points

  defp pack_f32(points) do
    for {x, y} <- points, into: <<>> do
      <<f32(x)::float-32, f32(y)::float-32>>
    end
  end

  defp f32(v), do: v * 1.0

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp eq32(a, b) do
    <<ia::32>> = <<f32(a)::float-32>>
    <<ib::32>> = <<f32(b)::float-32>>
    ia == ib
  end
end
