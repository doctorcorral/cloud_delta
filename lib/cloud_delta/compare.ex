defmodule CloudDelta.Compare do
  @moduledoc """
  Rate-distortion and baseline comparisons on real and synthetic clouds.

  Every size is a real encoded binary. RMSE is Euclidean, computed against
  the original points with `preserve_order` so pairing is exact. Relative
  RMSE is RMSE / bounding-box diagonal.

  Quantized LAZ and G-PCC (tmc3) run on the **same integer grid** as
  CloudDelta (`0 .. 2^bits-1` per axis). That is not industry 1 mm LAS
  scale, and it is not Draco's own quantizer — it is the fair same-grid
  comparison. Tools are skipped when missing (`TMC3`, `.tools/.venv`).

  Encode and decode times are wall-clock after the input is ready, median
  of 3: `CloudDelta.compress/2` / `uncompress_points/1`, `:zlib` and `zstd`
  on packed bytes, `draco_encoder` / `draco_decoder` on a PLY, laspy/lazrs
  read/write, and `tmc3` encode/decode. File writes used to feed the CLIs
  are not included. Elixir vs C++ is part of the result.
  """

  @bits [8, 10, 12, 14, 16]
  @dataset_root "priv/datasets"

  @doc """
  Built-in real clouds: Stanford scans, one automotive Velodyne frame, one
  terrestrial ALS tile, plus a 3D clustered synthetic.
  """
  def catalog do
    [
      %{
        id: "stanford_bun000",
        name: "Stanford bunny range scan bun000",
        kind: :scan,
        path: Path.join(@dataset_root, "bunny/data/bun000.ply"),
        loader: :ply
      },
      %{
        id: "stanford_bunny",
        name: "Stanford bunny zipper reconstruction",
        kind: :reconstruction,
        path: Path.join(@dataset_root, "bunny/reconstruction/bun_zipper.ply"),
        loader: :ply
      },
      %{
        id: "stanford_armadillo",
        name: "Stanford armadillo reconstruction",
        kind: :reconstruction,
        path: Path.join(@dataset_root, "Armadillo.ply"),
        loader: :ply
      },
      %{
        id: "lidar_kitti",
        name: "KITTI Velodyne HDL-64E frame 000000",
        kind: :automotive_lidar,
        path: Path.join(@dataset_root, "lidar/KITTI_Tiny/Kitti/predict/scans/000000.bin"),
        loader: :kitti_bin
      },
      %{
        id: "lidar_autzen",
        name: "Autzen stadium ALS trim (PDAL)",
        kind: :terrestrial_lidar,
        path: Path.join(@dataset_root, "lidar/autzen_trim.las"),
        loader: :las
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
    repeats = Keyword.get(opts, :repeats, 3)
    Process.put(:cd_compare_repeats, repeats)
    File.mkdir_p!("tmp")
    warmup()

    datasets =
      catalog()
      |> Enum.filter(&(&1.id in ids))
      |> Enum.map(&load_entry/1)
      |> Enum.reject(&is_nil/1)

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
      IO.puts("skip #{entry.id}: missing #{path}")
      nil
    else
      points = load_points(entry)
      Map.merge(entry, %{points: points, n: length(points)})
    end
  end

  defp load_points(%{loader: :kitti_bin, path: path}), do: CloudDelta.Lidar.load_kitti_bin(path)
  defp load_points(%{loader: :las, path: path}), do: CloudDelta.Lidar.load_las(path)
  defp load_points(%{path: path}), do: CloudDelta.Ply.load(path)

  defp lossless_row(id, kind, points) do
    n = length(points)
    dims = tuple_size(hd(points))
    raw = n * dims * 4
    packed = pack_f32(points)
    {zlib_b, zlib_ms, zlib_dec} = zlib_times(packed)
    {zstd_b, zstd_ms, zstd_dec} = zstd_times(packed)
    {bin, cd_ms} = median_timed(fn -> CloudDelta.compress(points, mode: :lossless) end)
    {_, cd_dec} = median_timed(fn -> CloudDelta.uncompress_points(bin) end)
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
      laz_bytes: nil,
      gpcc_bytes: nil,
      ratio: raw / max(cd_b, 1),
      zlib_ratio: raw / max(zlib_b, 1),
      zstd_ratio: raw / max(zstd_b, 1),
      vs_zstd: zstd_b / max(cd_b, 1),
      vs_laz: nil,
      vs_gpcc: nil,
      rmse: 0.0,
      rel_rmse: 0.0,
      lossless: ok?,
      encode_ms: cd_ms,
      cd_ms: cd_ms,
      zlib_ms: zlib_ms,
      zstd_ms: zstd_ms,
      draco_ms: nil,
      laz_ms: nil,
      gpcc_ms: nil,
      cd_dec_ms: cd_dec,
      zlib_dec_ms: zlib_dec,
      zstd_dec_ms: zstd_dec,
      draco_dec_ms: nil,
      laz_dec_ms: nil,
      gpcc_dec_ms: nil,
      cd_kpts: kpts(n, cd_ms)
    }
  end

  defp rd_row(id, kind, points, bits) do
    n = length(points)
    dims = tuple_size(hd(points))
    raw = n * dims * 4
    diag = bbox_diag(points)

    q = quantize_points(points, bits)
    packed_q = pack_quantized(q, bits)
    {zlib_q_b, zlib_ms, zlib_dec} = zlib_times(packed_q)
    {zstd_q, zstd_ms, zstd_dec} = zstd_times(packed_q)

    {bin, cd_ms} =
      median_timed(fn -> CloudDelta.compress(points, mode: :quantized, bits: bits) end)

    {_, cd_dec} = median_timed(fn -> CloudDelta.uncompress_points(bin) end)
    cd_b = byte_size(bin)

    ordered = CloudDelta.compress(points, mode: :quantized, bits: bits, preserve_order: true)
    restored = CloudDelta.uncompress_points(ordered)
    {rmse, rel} = rmse_pair(points, restored, diag)

    {draco_b, draco_ms, draco_dec} = draco_times(points, bits)
    {laz_b, laz_ms, laz_dec} = laz_times(q)
    {gpcc_b, gpcc_ms, gpcc_dec} = gpcc_times(q)

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
      zstd_bytes: zstd_size(pack_f32(points)),
      packed_q_bytes: byte_size(packed_q),
      zlib_q_bytes: zlib_q_b,
      zstd_q_bytes: zstd_q,
      draco_bytes: draco_b,
      laz_bytes: laz_b,
      gpcc_bytes: gpcc_b,
      ratio: raw / max(cd_b, 1),
      zlib_ratio: raw / max(byte_size(:zlib.compress(pack_f32(points))), 1),
      zstd_ratio: raw / max(zstd_size(pack_f32(points)), 1),
      vs_zstd_q: zstd_q / max(cd_b, 1),
      vs_draco: if(draco_b, do: draco_b / max(cd_b, 1), else: nil),
      vs_laz: if(laz_b, do: laz_b / max(cd_b, 1), else: nil),
      vs_gpcc: if(gpcc_b, do: gpcc_b / max(cd_b, 1), else: nil),
      rmse: rmse,
      rel_rmse: rel,
      lossless: false,
      encode_ms: cd_ms,
      cd_ms: cd_ms,
      zlib_ms: zlib_ms,
      zstd_ms: zstd_ms,
      draco_ms: draco_ms,
      laz_ms: laz_ms,
      gpcc_ms: gpcc_ms,
      cd_dec_ms: cd_dec,
      zlib_dec_ms: zlib_dec,
      zstd_dec_ms: zstd_dec,
      draco_dec_ms: draco_dec,
      laz_dec_ms: laz_dec,
      gpcc_dec_ms: gpcc_dec,
      cd_kpts: kpts(n, cd_ms)
    }
  end

  defp format_row(%{mode: :lossless} = r) do
    "lossless  cd=#{r.cloud_delta_bytes}B (#{f(r.ratio)}:1, enc=#{f(r.cd_ms)}ms dec=#{f(r.cd_dec_ms)}ms)  zlib enc=#{f(r.zlib_ms)}ms dec=#{f(r.zlib_dec_ms)}ms  zstd enc=#{f(r.zstd_ms)}ms dec=#{f(r.zstd_dec_ms)}ms  ok=#{r.lossless}"
  end

  defp format_row(r) do
    pair = fn enc_key, dec_key, label ->
      case {Map.get(r, enc_key), Map.get(r, dec_key)} do
        {nil, _} -> "#{label}=n/a"
        {enc, dec} -> "#{label} enc=#{f(enc)}ms dec=#{f(dec)}ms"
      end
    end

    "q#{r.bits}  cd enc=#{f(r.cd_ms)}ms dec=#{f(r.cd_dec_ms)}ms (#{r.cloud_delta_bytes}B)  #{pair.(:draco_ms, :draco_dec_ms, "draco")}  #{pair.(:laz_ms, :laz_dec_ms, "laz")}  #{pair.(:gpcc_ms, :gpcc_dec_ms, "gpcc")}"
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

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {result, us / 1000}
  end

  defp repeats, do: Process.get(:cd_compare_repeats, 3)

  defp median_timed(fun) do
    samples =
      for _ <- 1..repeats() do
        {result, ms} = timed(fun)
        {result, ms}
      end

    {result, _} = hd(samples)
    times = samples |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    {result, Enum.at(times, div(length(times), 2))}
  end

  defp median_pair(fun) do
    samples = for _ <- 1..repeats(), do: fun.()
    {result, _} = hd(samples)

    times =
      samples
      |> Enum.map(&elem(&1, 1))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    ms = if times == [], do: nil, else: Enum.at(times, div(length(times), 2))
    {result, ms}
  end

  defp kpts(_n, ms) when not is_number(ms) or ms <= 0, do: nil
  defp kpts(n, ms), do: n / ms

  defp warmup do
    points = CloudDelta.Benchmark.generate_points_3d(800, :clustered)
    bin = CloudDelta.compress(points, mode: :quantized, bits: 8)
    _ = CloudDelta.uncompress_points(bin)
    q = quantize_points(points, 8)
    packed = pack_f32(points)
    _ = zlib_times(packed)
    _ = zstd_times(packed)
    _ = draco_times(points, 8)
    _ = laz_times(q)
    _ = gpcc_times(q)
    :ok
  end

  defp zlib_times(payload) do
    {compressed, enc_ms} = median_timed(fn -> :zlib.compress(payload) end)
    {_, dec_ms} = median_timed(fn -> :zlib.uncompress(compressed) end)
    {byte_size(compressed), enc_ms, dec_ms}
  end

  defp zstd_times(binary) do
    dir = System.tmp_dir!()
    id = :erlang.unique_integer([:positive])
    inp = Path.join(dir, "cd_#{id}.bin")
    zst = Path.join(dir, "cd_#{id}.zst")
    File.write!(inp, binary)

    {_, enc_ms} =
      median_timed(fn ->
        {_, 0} = System.cmd("zstd", ["-q", "-f", "-o", zst, inp], stderr_to_stdout: true)
        :ok
      end)

    bytes = if File.exists?(zst), do: byte_size(File.read!(zst)), else: 0

    {_, dec_ms} =
      median_timed(fn ->
        {_, 0} = System.cmd("zstd", ["-q", "-d", "-c", zst], stderr_to_stdout: false)
        :ok
      end)

    File.rm(inp)
    File.rm(zst)
    {bytes, enc_ms, dec_ms}
  end

  defp zstd_size(binary) do
    dir = System.tmp_dir!()
    id = :erlang.unique_integer([:positive])
    inp = Path.join(dir, "cd_#{id}.bin")
    File.write!(inp, binary)
    {out, 0} = System.cmd("zstd", ["-q", "-c", inp], stderr_to_stdout: false)
    File.rm(inp)
    byte_size(out)
  end

  defp parse_py_ms(out, status) do
    case {status, String.split(String.trim(out))} do
      {0, [size_s, ms_s]} -> {String.to_integer(size_s), String.to_float(ms_s)}
      {0, [size_s]} -> {String.to_integer(size_s), nil}
      _ -> {nil, nil}
    end
  end

  defp draco_times(points, bits) do
    enc = System.find_executable("draco_encoder")
    dec = System.find_executable("draco_decoder")

    if is_nil(enc) or is_nil(dec) do
      {nil, nil, nil}
    else
      dir = System.tmp_dir!()
      id = :erlang.unique_integer([:positive])
      ply = Path.join(dir, "cd_#{id}.ply")
      drc = Path.join(dir, "cd_#{id}.drc")
      out = Path.join(dir, "cd_#{id}_out.ply")
      CloudDelta.Ply.write_xyz(ply, points)

      {status, enc_ms} =
        median_timed(fn ->
          {_, status} =
            System.cmd(
              enc,
              ["-point_cloud", "-i", ply, "-o", drc, "-qp", Integer.to_string(bits), "-cl", "10"],
              stderr_to_stdout: true
            )

          status
        end)

      bytes =
        if status == 0 and File.exists?(drc) do
          byte_size(File.read!(drc))
        else
          nil
        end

      {dec_status, dec_ms} =
        if bytes do
          median_timed(fn ->
            {_, status} =
              System.cmd(dec, ["-i", drc, "-o", out], stderr_to_stdout: true)

            status
          end)
        else
          {1, nil}
        end

      File.rm(ply)
      File.rm(drc)
      File.rm(out)

      {bytes, if(bytes, do: enc_ms, else: nil),
       if(bytes && dec_status == 0, do: dec_ms, else: nil)}
    end
  end

  defp laz_times(qpoints) do
    with true <- match?([_, _, _], hd(qpoints)),
         true <- CloudDelta.Lidar.laspy_available?() do
      dir = System.tmp_dir!()
      id = :erlang.unique_integer([:positive])
      ints = Path.join(dir, "cd_#{id}.i32")
      laz = Path.join(dir, "cd_#{id}.laz")
      File.write!(ints, pack_i32(qpoints))
      py = CloudDelta.Lidar.python!()
      script = CloudDelta.Lidar.script!()

      {bytes, enc_ms} =
        median_pair(fn ->
          {out, status} =
            System.cmd(py, [script, "encode-ints", ints, laz], stderr_to_stdout: true)

          parse_py_ms(out, status)
        end)

      {_, dec_ms} =
        if bytes do
          median_pair(fn ->
            {out, status} = System.cmd(py, [script, "decode", laz], stderr_to_stdout: true)
            parse_py_ms(out, status)
          end)
        else
          {nil, nil}
        end

      File.rm(ints)
      File.rm(laz)
      {bytes, enc_ms, dec_ms}
    else
      _ -> {nil, nil, nil}
    end
  end

  defp gpcc_times(qpoints) do
    with true <- match?([_, _, _], hd(qpoints)),
         bin when is_binary(bin) <- tmc3() do
      dir = System.tmp_dir!()
      id = :erlang.unique_integer([:positive])
      ply = Path.join(dir, "cd_#{id}.ply")
      stream = Path.join(dir, "cd_#{id}.bin")
      rec = Path.join(dir, "cd_#{id}_rec.ply")

      points = Enum.map(qpoints, fn [x, y, z] -> {x * 1.0, y * 1.0, z * 1.0} end)
      CloudDelta.Ply.write_xyz(ply, points)

      {status, enc_ms} =
        median_timed(fn ->
          {_, status} =
            System.cmd(
              bin,
              [
                "--mode=0",
                "--uncompressedDataPath=#{ply}",
                "--compressedStreamPath=#{stream}",
                "--mergeDuplicatedPoints=0",
                "--disableAttributeCoding=1",
                "--inferredDirectCodingMode=1",
                "--planarEnabled=1",
                "--trisoupNodeSizeLog2=0",
                "--codingScale=1",
                "--inputScale=1"
              ],
              stderr_to_stdout: true
            )

          status
        end)

      bytes =
        if status == 0 and File.exists?(stream) do
          byte_size(File.read!(stream))
        else
          nil
        end

      {dec_status, dec_ms} =
        if bytes do
          median_timed(fn ->
            {_, status} =
              System.cmd(
                bin,
                [
                  "--mode=1",
                  "--compressedStreamPath=#{stream}",
                  "--reconstructedDataPath=#{rec}"
                ],
                stderr_to_stdout: true
              )

            status
          end)
        else
          {1, nil}
        end

      File.rm(ply)
      File.rm(stream)
      File.rm(rec)

      {bytes, if(bytes, do: enc_ms, else: nil),
       if(bytes && dec_status == 0, do: dec_ms, else: nil)}
    else
      _ -> {nil, nil, nil}
    end
  end

  defp pack_i32(qpoints) do
    for qs <- qpoints, q <- qs, into: <<>>, do: <<q::signed-little-32>>
  end

  defp tmc3 do
    [
      System.get_env("TMC3"),
      Path.expand(".tools/tmc13/build/tmc3/tmc3"),
      System.find_executable("tmc3")
    ]
    |> Enum.find(fn
      nil -> false
      path -> File.regular?(path)
    end)
  end

  defp csv(rows) do
    header =
      "dataset,kind,n,mode,bits,raw_bytes,cd_bytes,zlib_q,zstd_q,draco,laz,gpcc,bpp,ratio,rmse,rel_rmse,cd_ms,zlib_ms,zstd_ms,draco_ms,laz_ms,gpcc_ms,cd_dec_ms,zlib_dec_ms,zstd_dec_ms,draco_dec_ms,laz_dec_ms,gpcc_dec_ms,cd_kpts\n"

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
            row.laz_bytes || "",
            row.gpcc_bytes || "",
            f(row.bpp),
            f(row.ratio),
            f(row.rmse),
            f(row.rel_rmse),
            f(row.cd_ms),
            f(row.zlib_ms),
            f(row.zstd_ms),
            f(row.draco_ms),
            f(row.laz_ms),
            f(row.gpcc_ms),
            f(row.cd_dec_ms),
            f(row.zlib_dec_ms),
            f(row.zstd_dec_ms),
            f(row.draco_dec_ms),
            f(row.laz_dec_ms),
            f(row.gpcc_dec_ms),
            f(row.cd_kpts)
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
