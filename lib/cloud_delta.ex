defmodule CloudDelta do
  @moduledoc """
  Point-set compression for 2D and 3D coordinates.

  CloudDelta treats a cloud as an unordered set of points. It reorders them
  for spatial locality (Morton order), optionally quantizes, delta-encodes,
  and entropy-codes residuals with zlib.

  ## Usage

      compressed = CloudDelta.compress({x, y}, mode: :quantized, bits: 16)
      {x2, y2} = CloudDelta.uncompress(compressed)

      compressed3 = CloudDelta.compress(xyz_tuples, mode: :quantized, bits: 12)
      points = CloudDelta.uncompress_points(compressed3)
  """

  alias CloudDelta.Codec

  @type point2 :: {number(), number()}
  @type point3 :: {number(), number(), number()}
  @type point :: point2() | point3()
  @type points_tensor ::
          {Nx.Tensor.t(), Nx.Tensor.t()} | {Nx.Tensor.t(), Nx.Tensor.t(), Nx.Tensor.t()}
  @type point_list :: [point()]
  @type compress_opt ::
          {:mode, :quantized | :lossless}
          | {:bits, pos_integer()}
          | {:preserve_order, boolean()}

  @doc """
  Compress a 2D or 3D point cloud.

  Accepts `{x, y}` or `{x, y, z}` Nx tensors, or a list of `{x, y}` / `{x, y, z}` tuples.

  Options:
    * `:mode` — `:quantized` (default) or `:lossless`
    * `:bits` — quantization bits per axis, `4..24` (default `16`)
    * `:preserve_order` — restore input order (default `false`)
  """
  @spec compress(points_tensor() | point_list(), [compress_opt()]) :: binary()
  def compress(points, opts \\ [])

  def compress({x, y, z}, opts) do
    Codec.encode(to_points(x, y, z), opts)
  end

  def compress({x, y}, opts) do
    Codec.encode(to_points(x, y), opts)
  end

  def compress(points, opts) when is_list(points) do
    Codec.encode(points, opts)
  end

  @doc """
  Decompress to coordinate tensors: `{x, y}` or `{x, y, z}`.
  """
  @spec uncompress(binary()) :: points_tensor()
  def uncompress(binary) when is_binary(binary) do
    {points, dims} = Codec.decode(binary)
    unzip_tensors(points, dims)
  end

  @doc """
  Decompress to a list of `{x, y}` or `{x, y, z}` floats.
  """
  @spec uncompress_points(binary()) :: point_list()
  def uncompress_points(binary) when is_binary(binary) do
    {points, _dims} = Codec.decode(binary)
    points
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
      |> Enum.all?(fn {a, b} -> eq_point(a, b) end)
  end

  @doc """
  Honest size statistics against packed float32 and zlib-on-raw-float32.
  """
  @spec stats(points_tensor() | point_list(), [compress_opt()]) :: map()
  def stats(points, opts \\ []) do
    list = normalize_points(points)
    n = length(list)
    dims = if n == 0, do: 2, else: tuple_size(hd(list))
    raw_bytes = n * dims * 4
    packed = pack_f32(list)
    zlib_bytes = byte_size(:zlib.compress(packed))
    compressed = compress(list, opts)
    compressed_bytes = byte_size(compressed)

    %{
      n: n,
      dims: dims,
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

  @doc false
  def to_points(%Nx.Tensor{} = x, %Nx.Tensor{} = y, %Nx.Tensor{} = z) do
    Enum.zip([Nx.to_flat_list(x), Nx.to_flat_list(y), Nx.to_flat_list(z)])
  end

  defp normalize_points({x, y, z}), do: to_points(x, y, z)
  defp normalize_points({x, y}), do: to_points(x, y)
  defp normalize_points(points) when is_list(points), do: points

  defp unzip_tensors([], 3) do
    empty = Nx.tensor([], type: :f32)
    {empty, empty, empty}
  end

  defp unzip_tensors([], _dims) do
    empty = Nx.tensor([], type: :f32)
    {empty, empty}
  end

  defp unzip_tensors(points, 3) do
    {xs, ys, zs} =
      Enum.reduce(points, {[], [], []}, fn {x, y, z}, {xs, ys, zs} ->
        {[x | xs], [y | ys], [z | zs]}
      end)

    {Nx.tensor(Enum.reverse(xs), type: :f32), Nx.tensor(Enum.reverse(ys), type: :f32),
     Nx.tensor(Enum.reverse(zs), type: :f32)}
  end

  defp unzip_tensors(points, _dims) do
    {xs, ys} =
      Enum.reduce(points, {[], []}, fn {x, y}, {xs, ys} ->
        {[x | xs], [y | ys]}
      end)

    {Nx.tensor(Enum.reverse(xs), type: :f32), Nx.tensor(Enum.reverse(ys), type: :f32)}
  end

  defp pack_f32(points) do
    for point <- points, into: <<>> do
      Enum.reduce(Tuple.to_list(point), <<>>, fn v, acc ->
        acc <> <<f32(v)::float-32>>
      end)
    end
  end

  defp f32(v), do: v * 1.0

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp eq_point(a, b) when tuple_size(a) == tuple_size(b) do
    Enum.zip(Tuple.to_list(a), Tuple.to_list(b))
    |> Enum.all?(fn {x, y} -> eq32(x, y) end)
  end

  defp eq_point(_, _), do: false

  defp eq32(a, b) do
    <<ia::32>> = <<f32(a)::float-32>>
    <<ib::32>> = <<f32(b)::float-32>>
    ia == ib
  end
end
