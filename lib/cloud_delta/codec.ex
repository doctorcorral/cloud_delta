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

    indexed =
      Enum.with_index(points, fn point, i ->
        {coords_of(point, dims), i}
      end)

    {payload, flags, bits, bbox} =
      case mode do
        :lossless ->
          {encode_lossless(indexed, dims, preserve), flag(true, preserve), 0,
           List.duplicate({0.0, 0.0}, dims)}

        :quantized ->
          {bin, bbox} = encode_quantized(indexed, dims, bits, preserve)
          {bin, flag(false, preserve), bits, bbox}

        other ->
          raise ArgumentError, "Unknown mode #{inspect(other)}"
      end

    n = length(points)
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

    if n == 0 do
      {[], dims}
    else
      raw = :zlib.uncompress(payload)

      points =
        if lossless? do
          decode_lossless(raw, n, dims, preserve?)
        else
          decode_quantized(raw, n, dims, bits, bbox, preserve?)
        end

      {points, dims}
    end
  end

  def decode(<<"CD1", _::binary>> = binary), do: decode_legacy_cd1(binary)

  def decode(_), do: raise(ArgumentError, "invalid CloudDelta binary")

  defp infer_dims([]), do: 2
  defp infer_dims([point | _]), do: tuple_size(point)

  defp coords_of(point, dims) when tuple_size(point) == dims do
    for i <- 0..(dims - 1), do: elem(point, i) * 1.0
  end

  defp coords_of(point, dims) do
    raise ArgumentError,
          "expected #{dims}D points, got #{tuple_size(point)}-tuple #{inspect(point)}"
  end

  defp flag(lossless?, preserve?) do
    if(lossless?, do: @flag_lossless, else: 0) |||
      if preserve?, do: @flag_preserve, else: 0
  end

  defp encode_bbox(bbox) do
    Enum.reduce(bbox, <<>>, fn {mn, mx}, acc ->
      acc <> <<mn::float-32, mx::float-32>>
    end)
  end

  defp decode_bbox(bin, dims), do: decode_bbox(bin, dims, [])

  defp decode_bbox(<<>>, 0, acc), do: Enum.reverse(acc)

  defp decode_bbox(<<mn::float-32, mx::float-32, rest::binary>>, left, acc) do
    decode_bbox(rest, left - 1, [{mn, mx} | acc])
  end

  # --- lossless ---

  defp encode_lossless([], _dims, _preserve), do: :zlib.compress(<<>>)

  defp encode_lossless(indexed, dims, preserve?) do
    ordered = Enum.sort_by(indexed, fn {coords, _i} -> coords end)
    {coords, orig} = unzip_indexed(ordered)
    body = IO.iodata_to_binary([encode_u32_deltas(coords, dims), maybe_perm(orig, preserve?)])
    :zlib.compress(body)
  end

  defp decode_lossless(raw, n, dims, preserve?) do
    {coords, rest} = decode_u32_deltas(raw, n, dims)

    coords =
      if preserve? do
        {perm, _} = decode_u32_list(rest, n)
        apply_perm(coords, perm)
      else
        coords
      end

    Enum.map(coords, &List.to_tuple/1)
  end

  defp encode_u32_deltas([first | rest], _dims) do
    p0 = Enum.map(first, &bits_of/1)
    header = Enum.reduce(p0, <<>>, fn u, acc -> acc <> <<u::32>> end)

    {iodata, _} =
      Enum.reduce(rest, {[header], p0}, fn coords, {acc, prev} ->
        cur = Enum.map(coords, &bits_of/1)

        deltas =
          Enum.zip(cur, prev)
          |> Enum.map(fn {c, p} -> uvarint(zigzag(to_signed32(wrap_sub(c, p)))) end)

        {[acc, deltas], cur}
      end)

    iodata
  end

  defp decode_u32_deltas(bin, n, dims) do
    {first, bin} = take_u32s(bin, dims)
    first_f = Enum.map(first, &float_of/1)

    if n <= 1 do
      {[first_f], bin}
    else
      {acc, _prev, rest} =
        Enum.reduce(1..(n - 1)//1, {[first_f], first, bin}, fn _, {acc, prev_u, bin} ->
          {signed, bin} =
            Enum.map_reduce(1..dims, bin, fn _, bin ->
              {z, bin} = take_uvarint(bin)
              {from_signed32(unzigzag(z)), bin}
            end)

          cur_u = Enum.zip(prev_u, signed) |> Enum.map(fn {p, d} -> wrap_add(p, d) end)
          {[Enum.map(cur_u, &float_of/1) | acc], cur_u, bin}
        end)

      {Enum.reverse(acc), rest}
    end
  end

  defp take_u32s(bin, 0), do: {[], bin}

  defp take_u32s(<<u::32, rest::binary>>, n) do
    {us, rest} = take_u32s(rest, n - 1)
    {[u | us], rest}
  end

  # --- quantized ---

  defp encode_quantized([], dims, _bits, _preserve) do
    {:zlib.compress(<<>>), List.duplicate({0.0, 0.0}, dims)}
  end

  defp encode_quantized(indexed, dims, bits, preserve?) do
    bbox =
      for d <- 0..(dims - 1) do
        vals = Enum.map(indexed, fn {coords, _} -> Enum.at(coords, d) end)
        {Enum.min(vals), Enum.max(vals)}
      end

    levels = (1 <<< bits) - 1

    quantized =
      Enum.map(indexed, fn {coords, i} ->
        q =
          Enum.zip(coords, bbox)
          |> Enum.map(fn {v, {mn, mx}} -> quantize(v, mn, mx, levels) end)

        {q, i}
      end)

    ordered =
      if bits <= 16 do
        Enum.sort_by(quantized, fn {q, _} -> morton(q) end)
      else
        Enum.sort_by(quantized, fn {q, _} -> q end)
      end

    {qcoords, orig} = unzip_indexed(ordered)
    body = IO.iodata_to_binary([encode_int_deltas(qcoords), maybe_perm(orig, preserve?)])
    {:zlib.compress(body), bbox}
  end

  defp decode_quantized(raw, n, dims, bits, bbox, preserve?) do
    levels = (1 <<< bits) - 1
    {qcoords, rest} = decode_int_deltas(raw, n, dims)

    qcoords =
      if preserve? do
        {perm, _} = decode_u32_list(rest, n)
        apply_perm(qcoords, perm)
      else
        qcoords
      end

    Enum.map(qcoords, fn q ->
      Enum.zip(q, bbox)
      |> Enum.map(fn {qi, {mn, mx}} -> dequantize(qi, mn, mx, levels) end)
      |> List.to_tuple()
    end)
  end

  defp encode_int_deltas([first | rest]) do
    header = Enum.map(first, &uvarint/1)

    {iodata, _} =
      Enum.reduce(rest, {[header], first}, fn cur, {acc, prev} ->
        deltas =
          Enum.zip(cur, prev)
          |> Enum.map(fn {c, p} -> uvarint(zigzag(c - p)) end)

        {[acc, deltas], cur}
      end)

    iodata
  end

  defp decode_int_deltas(bin, n, dims) do
    {first, bin} = take_n_varints(bin, dims)

    if n <= 1 do
      {[first], bin}
    else
      {acc, _prev, rest} =
        Enum.reduce(1..(n - 1)//1, {[first], first, bin}, fn _, {acc, prev, bin} ->
          {zs, bin} = take_n_varints(bin, dims)
          cur = Enum.zip(prev, zs) |> Enum.map(fn {p, z} -> p + unzigzag(z) end)
          {[cur | acc], cur, bin}
        end)

      {Enum.reverse(acc), rest}
    end
  end

  defp take_n_varints(bin, n) do
    Enum.map_reduce(1..n, bin, fn _, bin -> take_uvarint(bin) end)
  end

  defp maybe_perm(_orig, false), do: []
  defp maybe_perm(orig, true), do: Enum.map(orig, &uvarint/1)

  defp decode_u32_list(bin, n) do
    Enum.map_reduce(1..n, bin, fn _, bin -> take_uvarint(bin) end)
  end

  defp apply_perm(values, perm) do
    n = length(values)
    out = :array.new(n, default: nil)

    out =
      Enum.zip(values, perm)
      |> Enum.reduce(out, fn {v, i}, arr -> :array.set(i, v, arr) end)

    :array.to_list(out)
  end

  defp unzip_indexed(list) do
    {a, b} =
      Enum.reduce(list, {[], []}, fn {coords, i}, {cs, is} ->
        {[coords | cs], [i | is]}
      end)

    {Enum.reverse(a), Enum.reverse(b)}
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

  defp morton([x, y]), do: spread2(x) ||| spread2(y) <<< 1

  defp morton([x, y, z]) do
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

  defp uvarint(n) when n < 0, do: raise(ArgumentError, "uvarint of negative #{n}")
  defp uvarint(n) when n < 128, do: <<n>>
  defp uvarint(n), do: <<(n &&& 0x7F) ||| 0x80>> <> uvarint(n >>> 7)

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

  # Legacy v0.2 CD1 2-D binaries (still accepted).
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
          decode_lossless(raw, n, 2, preserve?)
        else
          decode_quantized(raw, n, 2, bits, [{xmin, xmax}, {ymin, ymax}], preserve?)
        end
      end

    {points, 2}
  end
end
