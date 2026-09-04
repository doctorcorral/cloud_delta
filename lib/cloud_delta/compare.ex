defmodule CloudDelta.Compare do
  @moduledoc """
  Rate-distortion and baseline comparisons on real and synthetic clouds.

  Every size is a real encoded binary. RMSE is Euclidean, computed against
  the original points with `preserve_order` so pairing is exact. Relative
  RMSE is RMSE / bounding-box diagonal.
  """

  @bits [8, 10, 12, 14, 16]
  @dataset_root "priv/datasets"

  @doc """
  Built-in real clouds (Stanford 3D Scanning Repository) plus a 3D clustered synthetic.
  """
  def catalog do
    [
      %{
        id: "stanford_bun000",
        name: "Stanford bunny range scan bun000",
        kind: :scan,
        path: Path.join(@dataset_root, "bunny/data/bun000.ply")
      },
      %{
        id: "stanford_bunny",
        name: "Stanford bunny zipper reconstruction",
        kind: :reconstruction,
        path: Path.join(@dataset_root, "bunny/reconstruction/bun_zipper.ply")
      },
      %{
        id: "stanford_armadillo",
        name: "Stanford armadillo reconstruction",
        kind: :reconstruction,
        path: Path.join(@dataset_root, "Armadillo.ply")
      },
      %{
        id: "synthetic_clustered_3d",
        name: "Synthetic 3D clustered (n=20,000)",
        kind: :synthetic,
        points: fn -> CloudDelta.Benchmark.generate_points_3d(20_000, :clustered) end
      }
    ]
  end

  @doc """
  Run the full comparison suite and write JSON + CSV under tmp/.
  """
  def run(opts \\ []) do
    bits = Keyword.get(opts, :bits, @bits)
    ids = Keyword.get(opts, :ids, Enum.map(catalog(), & &1.id))
    File.mkdir_p!("tmp")

    datasets =
      catalog()
      |> Enum.filter(&(&1.id in ids))
      |> Enum.map(&load_entry/1)

    rows =
      for %{id: id, name: name, kind: kind, points: points} <- datasets do
        IO.puts("\n=== #{id} (#{length(points)} pts, #{name}) ===")
        lossless = lossless_row(id, kind, points)
        IO.puts(format_row(lossless))

        rd =
          for b <- bits do
            row = rd_row(id, kind, points, b)
            IO.puts(format_row(row))
            row
          end

        %{id: id, name: name, kind: kind, n: length(points), lossless: lossless, rd: rd}
      end

    json = encode_json(rows)
    File.write!("tmp/rd_results.json", json)
    File.write!("tmp/rd_results.csv", csv(rows))
    IO.puts("\nWrote tmp/rd_results.json and tmp/rd_results.csv")
    rows
  end

  defp load_entry(%{points: fun} = entry) when is_function(fun, 0) do
    points = fun.()
    Map.merge(entry, %{points: points, n: length(points)})
  end

  defp load_entry(%{path: path} = entry) do
    unless File.exists?(path) do
      raise "Missing dataset #{path}. Expected Stanford PLYs under priv/datasets/."
    end

    points = CloudDelta.Ply.load(path)
    Map.merge(entry, %{points: points, n: length(points)})
  end

  defp lossless_row(id, kind, points) do
    n = length(points)
    dims = tuple_size(hd(points))
    raw = n * dims * 4
    packed = pack_f32(points)
    zlib_b = byte_size(:zlib.compress(packed))
    zstd_b = zstd(packed)

    {us, bin} = :timer.tc(fn -> CloudDelta.compress(points, mode: :lossless) end)
    cd_b = byte_size(bin)
    ok? = CloudDelta.check_compression(points)

    %{
      dataset: id,
      kind: kind,
      n: n,
      dims: dims,
      mode: :lossless,
      bits: 32,
      raw_bytes: raw,
      bpp: bpp(cd_b, n),
      raw_bpp: bpp(raw, n),
      cloud_delta_bytes: cd_b,
      zlib_bytes: zlib_b,
      zstd_bytes: zstd_b,
      packed_q_bytes: raw,
      zlib_q_bytes: zlib_b,
      zstd_q_bytes: zstd_b,
      draco_bytes: nil,
      ratio: raw / max(cd_b, 1),
      zlib_ratio: raw / max(zlib_b, 1),
      zstd_ratio: raw / max(zstd_b, 1),
      vs_zstd: zstd_b / max(cd_b, 1),
      rmse: 0.0,
      rel_rmse: 0.0,
      lossless: ok?,
      encode_ms: us / 1000
    }
  end

  defp rd_row(id, kind, points, bits) do
    n = length(points)
    dims = tuple_size(hd(points))
    raw = n * dims * 4
    diag = bbox_diag(points)

    q = quantize_points(points, bits)
    packed_q = pack_quantized(q, bits)
    zlib_q = :zlib.compress(packed_q)
    zstd_q = zstd(packed_q)

    {us, bin} = :timer.tc(fn -> CloudDelta.compress(points, mode: :quantized, bits: bits) end)
    cd_b = byte_size(bin)

    ordered = CloudDelta.compress(points, mode: :quantized, bits: bits, preserve_order: true)
    restored = CloudDelta.uncompress_points(ordered)
    {rmse, rel} = rmse_pair(points, restored, diag)

    draco_b = draco_bytes(points, bits)

    %{
      dataset: id,
      kind: kind,
      n: n,
      dims: dims,
      mode: :quantized,
      bits: bits,
      raw_bytes: raw,
      bpp: bpp(cd_b, n),
      raw_bpp: bpp(raw, n),
      cloud_delta_bytes: cd_b,
      zlib_bytes: byte_size(:zlib.compress(pack_f32(points))),
      zstd_bytes: zstd(pack_f32(points)),
      packed_q_bytes: byte_size(packed_q),
      zlib_q_bytes: byte_size(zlib_q),
      zstd_q_bytes: zstd_q,
      draco_bytes: draco_b,
      ratio: raw / max(cd_b, 1),
      zlib_ratio: raw / max(byte_size(:zlib.compress(pack_f32(points))), 1),
      zstd_ratio: raw / max(zstd(pack_f32(points)), 1),
      vs_zstd_q: zstd_q / max(cd_b, 1),
      vs_draco: if(draco_b, do: draco_b / max(cd_b, 1), else: nil),
      rmse: rmse,
      rel_rmse: rel,
      lossless: false,
      encode_ms: us / 1000
    }
  end

  defp format_row(%{mode: :lossless} = r) do
    "lossless  cd=#{r.cloud_delta_bytes}B (#{f(r.ratio)}:1)  zlib=#{f(r.zlib_ratio)}:1  zstd=#{f(r.zstd_ratio)}:1  ok=#{r.lossless}"
  end

  defp format_row(r) do
    draco =
      if r.draco_bytes,
        do: "draco=#{r.draco_bytes}B",
        else: "draco=n/a"

    "q#{r.bits}  cd=#{r.cloud_delta_bytes}B (#{f(r.ratio)}:1, #{f(r.bpp)} bpp)  q+zstd=#{r.zstd_q_bytes}B  #{draco}  relRMSE=#{f(r.rel_rmse)}"
  end

  defp pack_f32(points) do
    for point <- points, into: <<>> do
      Enum.reduce(Tuple.to_list(point), <<>>, fn v, acc ->
        acc <> <<v * 1.0::float-32>>
      end)
    end
  end

  defp quantize_points(points, bits) do
    dims = tuple_size(hd(points))
    levels = Bitwise.bsl(1, bits) - 1

    bbox =
      for d <- 0..(dims - 1) do
        vals = Enum.map(points, &elem(&1, d))
        {Enum.min(vals), Enum.max(vals)}
      end

    Enum.map(points, fn point ->
      Tuple.to_list(point)
      |> Enum.zip(bbox)
      |> Enum.map(fn {v, {mn, mx}} ->
        if mn == mx do
          0
        else
          q = round((v - mn) / (mx - mn) * levels)
          min(max(q, 0), levels)
        end
      end)
    end)
  end

  defp pack_quantized(qpoints, bits) do
    bin = for qs <- qpoints, q <- qs, into: <<>>, do: <<q::size(bits)>>
    pad = rem(8 - rem(bit_size(bin), 8), 8)
    <<bin::bitstring, 0::size(pad)>>
  end

  defp bbox_diag(points) do
    dims = tuple_size(hd(points))

    spans =
      for d <- 0..(dims - 1) do
        vals = Enum.map(points, &elem(&1, d))
        Enum.max(vals) - Enum.min(vals)
      end

    :math.sqrt(Enum.reduce(spans, 0.0, fn s, acc -> acc + s * s end))
  end

  defp rmse_pair(orig, rest, diag) do
    n = length(orig)

    sse =
      Enum.zip(orig, rest)
      |> Enum.reduce(0.0, fn {a, b}, acc ->
        acc +
          (Tuple.to_list(a)
           |> Enum.zip(Tuple.to_list(b))
           |> Enum.reduce(0.0, fn {x, y}, s ->
             d = x - y
             s + d * d
           end))
      end)

    rmse = :math.sqrt(sse / max(n, 1))
    rel = if diag > 0, do: rmse / diag, else: 0.0
    {rmse, rel}
  end

  defp bpp(bytes, n) when n > 0, do: bytes * 8.0 / n
  defp bpp(_, _), do: 0.0

  defp zstd(binary) do
    dir = System.tmp_dir!()
    id = :erlang.unique_integer([:positive])
    inp = Path.join(dir, "cd_#{id}.bin")
    File.write!(inp, binary)

    {out, 0} = System.cmd("zstd", ["-q", "-c", inp], stderr_to_stdout: false)
    File.rm(inp)
    byte_size(out)
  end

  defp draco_bytes(points, bits) do
    case System.find_executable("draco_encoder") do
      nil ->
        nil

      enc ->
        dir = System.tmp_dir!()
        id = :erlang.unique_integer([:positive])
        ply = Path.join(dir, "cd_#{id}.ply")
        drc = Path.join(dir, "cd_#{id}.drc")
        CloudDelta.Ply.write_xyz(ply, points)

        {_, status} =
          System.cmd(
            enc,
            ["-point_cloud", "-i", ply, "-o", drc, "-qp", Integer.to_string(bits), "-cl", "10"],
            stderr_to_stdout: true
          )

        bytes =
          if status == 0 and File.exists?(drc) do
            byte_size(File.read!(drc))
          else
            nil
          end

        File.rm(ply)
        File.rm(drc)
        bytes
    end
  end

  defp csv(rows) do
    header =
      "dataset,kind,n,mode,bits,raw_bytes,cd_bytes,zlib_q,zstd_q,draco,bpp,ratio,rmse,rel_rmse\n"

    body =
      for set <- rows, row <- [set.lossless | set.rd] do
        Enum.join(
          [
            row.dataset,
            row.kind,
            row.n,
            row.mode,
            row.bits,
            row.raw_bytes,
            row.cloud_delta_bytes,
            row.zlib_q_bytes,
            row.zstd_q_bytes,
            row.draco_bytes || "",
            f(row.bpp),
            f(row.ratio),
            f(row.rmse),
            f(row.rel_rmse)
          ],
          ","
        ) <> "\n"
      end

    [header | body]
  end

  defp encode_json(term), do: :erlang.iolist_to_binary(json(term))

  defp json(map) when is_map(map) do
    pairs =
      Enum.map(map, fn {k, v} -> [json(to_string(k)), ":", json(v)] end)
      |> Enum.intersperse(",")

    ["{", pairs, "}"]
  end

  defp json(list) when is_list(list) do
    ["[", Enum.intersperse(Enum.map(list, &json/1), ","), "]"]
  end

  defp json(true), do: "true"
  defp json(false), do: "false"
  defp json(nil), do: "null"
  defp json(x) when is_integer(x), do: Integer.to_string(x)
  defp json(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 8)
  defp json(x) when is_atom(x), do: json(Atom.to_string(x))
  defp json(x) when is_binary(x), do: [?"] ++ escape(x) ++ [?"]
  defp json(other), do: json(inspect(other))

  defp escape(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.to_charlist()
  end

  defp f(nil), do: "n/a"
  defp f(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 4)
  defp f(x), do: to_string(x)
end
