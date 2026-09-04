defmodule CloudDelta.Codec do
  @moduledoc false

  import Bitwise

  @magic "CD2"
  @version 1
  @flag_lossless 0b0000_0001
  @flag_preserve 0b0000_0010

  @spec encode([tuple()], keyword()) :: binary()
  def encode(points, opts) when is_list(points) do
    mode = Keyword.get(opts, :mode, :quantized)
    preserve = Keyword.get(opts, :preserve_order, false)
    bits = Keyword.get(opts, :bits, 16)

    if bits < 4 or bits > 24 do
      raise ArgumentError, "bits must be in 4..24, got #{inspect(bits)}"
    end

    dims = infer_dims(points)

    if dims not in [2, 3] do
      raise ArgumentError, "CloudDelta supports 2D or 3D points, got #{dims}D"
    end

    {payload, flags, bits, bbox, n} =
      case {mode, dims, points} do
        {_, _, []} ->
          {:zlib.compress(<<>>), flag(mode == :lossless, preserve),
           if(mode == :lossless, do: 0, else: bits), List.duplicate({0.0, 0.0}, dims), 0}

        {:quantized, 3, _} ->
          {bin, bbox, n} = encode_q3(points, bits, preserve)
          {bin, flag(false, preserve), bits, bbox, n}

        {:quantized, 2, _} ->
          {bin, bbox, n} = encode_q2(points, bits, preserve)
          {bin, flag(false, preserve), bits, bbox, n}

        {:lossless, 3, _} ->
          {bin, n} = encode_l3(points, preserve)
          {bin, flag(true, preserve), 0, [{0.0, 0.0}, {0.0, 0.0}, {0.0, 0.0}], n}

        {:lossless, 2, _} ->
          {bin, n} = encode_l2(points, preserve)
          {bin, flag(true, preserve), 0, [{0.0, 0.0}, {0.0, 0.0}], n}

        {other, _, _} ->
          raise ArgumentError, "Unknown mode #{inspect(other)}"
      end

    bbox_bin = encode_bbox(bbox)
    <<@magic, @version::8, flags::8, dims::8, n::32, bits::8, bbox_bin::binary, payload::binary>>
  end

  @spec decode(binary()) :: {[tuple()], pos_integer()}
  def decode(<<"CD2", @version::8, flags::8, dims::8, n::32, bits::8, rest::binary>>)
      when dims in [2, 3] do
    bbox_bytes = dims * 8
    <<bbox_bin::binary-size(bbox_bytes), payload::binary>> = rest
    bbox = decode_bbox(bbox_bin, dims)
    lossless? = (flags &&& @flag_lossless) != 0
    preserve? = (flags &&& @flag_preserve) != 0

    points =
      cond do
        n == 0 ->
          []

        lossless? and dims == 3 ->
          decode_l3(:zlib.uncompress(payload), n, preserve?)

        lossless? ->
          decode_l2(:zlib.uncompress(payload), n, preserve?)

        dims == 3 ->
          decode_q3(:zlib.uncompress(payload), n, bits, bbox, preserve?)

        true ->
          decode_q2(:zlib.uncompress(payload), n, bits, bbox, preserve?)
      end

    {points, dims}
  end

  def decode(<<"CD1", _::binary>> = binary), do: decode_legacy_cd1(binary)

  def decode(_), do: raise(ArgumentError, "invalid CloudDelta binary")

  defp infer_dims([]), do: 2
  defp infer_dims([point | _]), do: tuple_size(point)

  defp flag(lossless?, preserve?) do
    if(lossless?, do: @flag_lossless, else: 0) |||
      if preserve?, do: @flag_preserve, else: 0
  end

  defp encode_bbox(bbox) do
    for {mn, mx} <- bbox, into: <<>>, do: <<mn::float-32, mx::float-32>>
  end

  defp decode_bbox(<<xmin::float-32, xmax::float-32, ymin::float-32, ymax::float-32>>, 2) do
    {xmin, xmax, ymin, ymax}
  end

  defp decode_bbox(
         <<xmin::float-32, xmax::float-32, ymin::float-32, ymax::float-32, zmin::float-32,
           zmax::float-32>>,
         3
       ) do
    {xmin, xmax, ymin, ymax, zmin, zmax}
  end

  # --- quantized 3D ---

  defp encode_q3(points, bits, preserve?) do
    {x0, x1, y0, y1, z0, z1, n} = bbox3(points)
    levels = (1 <<< bits) - 1
    rows = qrows3(points, x0, x1, y0, y1, z0, z1, levels, bits <= 16, 0, [])
    ordered = :lists.sort(rows)
    body = deltas3(ordered, preserve?)
    {:zlib.compress(body), [{x0, x1}, {y0, y1}, {z0, z1}], n}
  end

  defp bbox3([{x, y, z} | rest]) do
    x = x * 1.0
    y = y * 1.0
    z = z * 1.0
    bbox3(rest, x, x, y, y, z, z, 1)
  end

  defp bbox3([{x, y, z} | rest], x0, x1, y0, y1, z0, z1, n) do
    x = x * 1.0
    y = y * 1.0
    z = z * 1.0

    bbox3(
      rest,
      min(x0, x),
      max(x1, x),
      min(y0, y),
      max(y1, y),
      min(z0, z),
      max(z1, z),
      n + 1
    )
  end

  defp bbox3([], x0, x1, y0, y1, z0, z1, n), do: {x0, x1, y0, y1, z0, z1, n}

  defp qrows3([{x, y, z} | rest], x0, x1, y0, y1, z0, z1, levels, morton?, i, acc) do
    qx = quantize(x * 1.0, x0, x1, levels)
    qy = quantize(y * 1.0, y0, y1, levels)
    qz = quantize(z * 1.0, z0, z1, levels)

    row =
      if morton? do
        {morton3(qx, qy, qz), qx, qy, qz, i}
      else
        {qx, qy, qz, i}
      end

    qrows3(rest, x0, x1, y0, y1, z0, z1, levels, morton?, i + 1, [row | acc])
  end

  defp qrows3([], _, _, _, _, _, _, _, _, _, acc), do: acc

  defp deltas3([row | rest], preserve?) do
    {x, y, z, i} = qxyz(row)
    acc = [uvarint(x), uvarint(y), uvarint(z)]
    perm = if preserve?, do: [uvarint(i)], else: []
    deltas3(rest, x, y, z, acc, perm, preserve?)
  end

  defp deltas3([row | rest], px, py, pz, acc, perm, preserve?) do
    {x, y, z, i} = qxyz(row)

    acc = [
      acc,
      uvarint(zigzag(x - px)),
      uvarint(zigzag(y - py)),
      uvarint(zigzag(z - pz))
    ]

    perm = if preserve?, do: [perm, uvarint(i)], else: perm
    deltas3(rest, x, y, z, acc, perm, preserve?)
  end

  defp deltas3([], _px, _py, _pz, acc, perm, _preserve?) do
    IO.iodata_to_binary([acc, perm])
  end

  defp qxyz({_m, x, y, z, i}), do: {x, y, z, i}
  defp qxyz({x, y, z, i}), do: {x, y, z, i}

  defp decode_q3(raw, n, bits, {x0, x1, y0, y1, z0, z1}, preserve?) do
    levels = (1 <<< bits) - 1
    {qx, raw} = take_uvarint(raw)
    {qy, raw} = take_uvarint(raw)
    {qz, raw} = take_uvarint(raw)
    {qs, rest} = walk_q3(raw, n - 1, qx, qy, qz, [{qx, qy, qz}])
    qs = maybe_unperm(qs, rest, n, preserve?)
    deq3(qs, x0, x1, y0, y1, z0, z1, levels)
  end

  defp walk_q3(bin, 0, _x, _y, _z, acc), do: {:lists.reverse(acc), bin}

  defp walk_q3(bin, left, px, py, pz, acc) do
    {dx, bin} = take_uvarint(bin)
    {dy, bin} = take_uvarint(bin)
    {dz, bin} = take_uvarint(bin)
    x = px + unzigzag(dx)
    y = py + unzigzag(dy)
    z = pz + unzigzag(dz)
    walk_q3(bin, left - 1, x, y, z, [{x, y, z} | acc])
  end

  defp deq3(qs, x0, x1, y0, y1, z0, z1, levels) do
    Enum.map(qs, fn {qx, qy, qz} ->
      {dequantize(qx, x0, x1, levels), dequantize(qy, y0, y1, levels),
       dequantize(qz, z0, z1, levels)}
    end)
  end

  # --- quantized 2D ---

  defp encode_q2(points, bits, preserve?) do
    {x0, x1, y0, y1, n} = bbox2(points)
    levels = (1 <<< bits) - 1
    rows = qrows2(points, x0, x1, y0, y1, levels, bits <= 16, 0, [])
    ordered = :lists.sort(rows)
    body = deltas2(ordered, preserve?)
    {:zlib.compress(body), [{x0, x1}, {y0, y1}], n}
  end

  defp bbox2([{x, y} | rest]) do
    x = x * 1.0
    y = y * 1.0
    bbox2(rest, x, x, y, y, 1)
  end

  defp bbox2([{x, y} | rest], x0, x1, y0, y1, n) do
    x = x * 1.0
    y = y * 1.0
    bbox2(rest, min(x0, x), max(x1, x), min(y0, y), max(y1, y), n + 1)
  end

  defp bbox2([], x0, x1, y0, y1, n), do: {x0, x1, y0, y1, n}

  defp qrows2([{x, y} | rest], x0, x1, y0, y1, levels, morton?, i, acc) do
    qx = quantize(x * 1.0, x0, x1, levels)
    qy = quantize(y * 1.0, y0, y1, levels)

    row =
      if morton? do
        {morton2(qx, qy), qx, qy, i}
      else
        {qx, qy, i}
      end

    qrows2(rest, x0, x1, y0, y1, levels, morton?, i + 1, [row | acc])
  end

  defp qrows2([], _, _, _, _, _, _, _, acc), do: acc

  defp deltas2([row | rest], preserve?) do
    {x, y, i} = qxy(row)
    acc = [uvarint(x), uvarint(y)]
    perm = if preserve?, do: [uvarint(i)], else: []
    deltas2(rest, x, y, acc, perm, preserve?)
  end

  defp deltas2([row | rest], px, py, acc, perm, preserve?) do
    {x, y, i} = qxy(row)
    acc = [acc, uvarint(zigzag(x - px)), uvarint(zigzag(y - py))]
    perm = if preserve?, do: [perm, uvarint(i)], else: perm
    deltas2(rest, x, y, acc, perm, preserve?)
  end

  defp deltas2([], _px, _py, acc, perm, _preserve?) do
    IO.iodata_to_binary([acc, perm])
  end

  defp qxy({_m, x, y, i}), do: {x, y, i}
  defp qxy({x, y, i}), do: {x, y, i}

  defp decode_q2(raw, n, bits, {x0, x1, y0, y1}, preserve?) do
    levels = (1 <<< bits) - 1
    {qx, raw} = take_uvarint(raw)
    {qy, raw} = take_uvarint(raw)
    {qs, rest} = walk_q2(raw, n - 1, qx, qy, [{qx, qy}])
    qs = maybe_unperm(qs, rest, n, preserve?)

    Enum.map(qs, fn {qx, qy} ->
      {dequantize(qx, x0, x1, levels), dequantize(qy, y0, y1, levels)}
    end)
  end

  defp walk_q2(bin, 0, _x, _y, acc), do: {:lists.reverse(acc), bin}

  defp walk_q2(bin, left, px, py, acc) do
    {dx, bin} = take_uvarint(bin)
    {dy, bin} = take_uvarint(bin)
    x = px + unzigzag(dx)
    y = py + unzigzag(dy)
    walk_q2(bin, left - 1, x, y, [{x, y} | acc])
  end

  # --- lossless ---

  defp encode_l3(points, preserve?) do
    {rows, n} = index3(points, 0, [])
    body = u32_d3(:lists.sort(rows), preserve?)
    {:zlib.compress(body), n}
  end

  defp encode_l2(points, preserve?) do
    {rows, n} = index2(points, 0, [])
    body = u32_d2(:lists.sort(rows), preserve?)
    {:zlib.compress(body), n}
  end

  defp index3([{x, y, z} | rest], i, acc) do
    index3(rest, i + 1, [{x * 1.0, y * 1.0, z * 1.0, i} | acc])
  end

  defp index3([], n, acc), do: {acc, n}

  defp index2([{x, y} | rest], i, acc) do
    index2(rest, i + 1, [{x * 1.0, y * 1.0, i} | acc])
  end

  defp index2([], n, acc), do: {acc, n}

  defp u32_d3([{x, y, z, i} | rest], preserve?) do
    ux = bits_of(x)
    uy = bits_of(y)
    uz = bits_of(z)
    acc = [<<ux::32, uy::32, uz::32>>]
    perm = if preserve?, do: [uvarint(i)], else: []
    u32_d3(rest, ux, uy, uz, acc, perm, preserve?)
  end

  defp u32_d3([{x, y, z, i} | rest], px, py, pz, acc, perm, preserve?) do
    ux = bits_of(x)
    uy = bits_of(y)
    uz = bits_of(z)

    acc = [
      acc,
      uvarint(zigzag(to_signed32(wrap_sub(ux, px)))),
      uvarint(zigzag(to_signed32(wrap_sub(uy, py)))),
      uvarint(zigzag(to_signed32(wrap_sub(uz, pz))))
    ]

    perm = if preserve?, do: [perm, uvarint(i)], else: perm
    u32_d3(rest, ux, uy, uz, acc, perm, preserve?)
  end

  defp u32_d3([], _px, _py, _pz, acc, perm, _preserve?) do
    IO.iodata_to_binary([acc, perm])
  end

  defp u32_d2([{x, y, i} | rest], preserve?) do
    ux = bits_of(x)
    uy = bits_of(y)
    acc = [<<ux::32, uy::32>>]
    perm = if preserve?, do: [uvarint(i)], else: []
    u32_d2(rest, ux, uy, acc, perm, preserve?)
  end

  defp u32_d2([{x, y, i} | rest], px, py, acc, perm, preserve?) do
    ux = bits_of(x)
    uy = bits_of(y)

    acc = [
      acc,
      uvarint(zigzag(to_signed32(wrap_sub(ux, px)))),
      uvarint(zigzag(to_signed32(wrap_sub(uy, py))))
    ]

    perm = if preserve?, do: [perm, uvarint(i)], else: perm
    u32_d2(rest, ux, uy, acc, perm, preserve?)
  end

  defp u32_d2([], _px, _py, acc, perm, _preserve?) do
    IO.iodata_to_binary([acc, perm])
  end

  defp decode_l3(<<ux::32, uy::32, uz::32, rest::binary>>, n, preserve?) do
    {pts, rest} = walk_l3(rest, n - 1, ux, uy, uz, [{float_of(ux), float_of(uy), float_of(uz)}])
    maybe_unperm(pts, rest, n, preserve?)
  end

  defp walk_l3(bin, 0, _x, _y, _z, acc), do: {:lists.reverse(acc), bin}

  defp walk_l3(bin, left, px, py, pz, acc) do
    {dx, bin} = take_uvarint(bin)
    {dy, bin} = take_uvarint(bin)
    {dz, bin} = take_uvarint(bin)
    ux = wrap_add(px, from_signed32(unzigzag(dx)))
    uy = wrap_add(py, from_signed32(unzigzag(dy)))
    uz = wrap_add(pz, from_signed32(unzigzag(dz)))
    walk_l3(bin, left - 1, ux, uy, uz, [{float_of(ux), float_of(uy), float_of(uz)} | acc])
  end

  defp decode_l2(<<ux::32, uy::32, rest::binary>>, n, preserve?) do
    {pts, rest} = walk_l2(rest, n - 1, ux, uy, [{float_of(ux), float_of(uy)}])
    maybe_unperm(pts, rest, n, preserve?)
  end

  defp walk_l2(bin, 0, _x, _y, acc), do: {:lists.reverse(acc), bin}

  defp walk_l2(bin, left, px, py, acc) do
    {dx, bin} = take_uvarint(bin)
    {dy, bin} = take_uvarint(bin)
    ux = wrap_add(px, from_signed32(unzigzag(dx)))
    uy = wrap_add(py, from_signed32(unzigzag(dy)))
    walk_l2(bin, left - 1, ux, uy, [{float_of(ux), float_of(uy)} | acc])
  end

  defp maybe_unperm(values, _bin, _n, false), do: values

  defp maybe_unperm(values, bin, n, true) do
    {perm, _} = take_n_varints(bin, n)
    apply_perm(values, perm)
  end

  defp take_n_varints(bin, n), do: take_n_varints(bin, n, [])
  defp take_n_varints(bin, 0, acc), do: {:lists.reverse(acc), bin}

  defp take_n_varints(bin, n, acc) do
    {v, bin} = take_uvarint(bin)
    take_n_varints(bin, n - 1, [v | acc])
  end

  defp apply_perm(values, perm) do
    n = length(values)
    out = :array.new(n, default: nil)

    out =
      Enum.zip(values, perm)
      |> Enum.reduce(out, fn {v, i}, arr -> :array.set(i, v, arr) end)

    :array.to_list(out)
  end

  defp quantize(_v, min, max, _levels) when min == max, do: 0

  defp quantize(v, min, max, levels) do
    q = round((v - min) / (max - min) * levels)
    min(max(q, 0), levels)
  end

  defp dequantize(_q, min, max, _levels) when min == max, do: min

  defp dequantize(q, min, max, levels) do
    min + q / levels * (max - min)
  end

  defp morton2(x, y), do: spread2(x) ||| spread2(y) <<< 1

  defp morton3(x, y, z) do
    spread3(x) ||| spread3(y) <<< 1 ||| spread3(z) <<< 2
  end

  defp spread2(n) do
    n = n &&& 0xFFFF
    n = (n ||| n <<< 8) &&& 0x00FF00FF
    n = (n ||| n <<< 4) &&& 0x0F0F0F0F
    n = (n ||| n <<< 2) &&& 0x33333333
    (n ||| n <<< 1) &&& 0x55555555
  end

  defp spread3(n) do
    n = n &&& 0x1FFFFF
    n = (n ||| n <<< 32) &&& 0x1F00000000FFFF
    n = (n ||| n <<< 16) &&& 0x1F0000FF0000FF
    n = (n ||| n <<< 8) &&& 0x100F00F00F00F00F
    n = (n ||| n <<< 4) &&& 0x10C30C30C30C30C3
    (n ||| n <<< 2) &&& 0x1249249249249249
  end

  defp bits_of(f) do
    <<u::32>> = <<f * 1.0::float-32>>
    u
  end

  defp float_of(u) do
    <<f::float-32>> = <<u::32>>
    f
  end

  defp wrap_sub(a, b), do: a - b &&& 0xFFFFFFFF
  defp wrap_add(a, d), do: a + d &&& 0xFFFFFFFF

  defp to_signed32(u) when u >= 0x80000000, do: u - 0x100000000
  defp to_signed32(u), do: u

  defp from_signed32(s) when s < 0, do: s + 0x100000000
  defp from_signed32(s), do: s

  defp zigzag(n) when is_integer(n), do: bxor(n <<< 1, n >>> 31)
  defp unzigzag(n) when is_integer(n), do: bxor(n >>> 1, -(n &&& 1))

  # Byte integers are valid iodata (0..255). Avoids allocating a 1-byte binary
  # for the common single-byte varint case.
  defp uvarint(n) when n < 0, do: raise(ArgumentError, "uvarint of negative #{n}")
  defp uvarint(n) when n < 128, do: n
  defp uvarint(n), do: [(n &&& 0x7F) ||| 0x80, uvarint(n >>> 7)]

  defp take_uvarint(<<b, rest::binary>>) when b < 128, do: {b, rest}
  defp take_uvarint(bin), do: take_uvarint(bin, 0, 0)

  defp take_uvarint(<<b, rest::binary>>, shift, acc) do
    acc = acc ||| (b &&& 0x7F) <<< shift

    if (b &&& 0x80) == 0 do
      {acc, rest}
    else
      take_uvarint(rest, shift + 7, acc)
    end
  end

  defp take_uvarint(<<>>, _, _), do: raise(ArgumentError, "truncated varint")

  defp decode_legacy_cd1(
         <<"CD1", 1::8, flags::8, n::32, bits::8, xmin::float-32, xmax::float-32, ymin::float-32,
           ymax::float-32, payload::binary>>
       ) do
    lossless? = (flags &&& @flag_lossless) != 0
    preserve? = (flags &&& @flag_preserve) != 0

    points =
      if n == 0 do
        []
      else
        raw = :zlib.uncompress(payload)

        if lossless? do
          decode_l2(raw, n, preserve?)
        else
          decode_q2(raw, n, bits, {xmin, xmax, ymin, ymax}, preserve?)
        end
      end

    {points, 2}
  end
end
