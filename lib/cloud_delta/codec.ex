defmodule CloudDelta.Codec do
  @moduledoc false

  import Bitwise

  @magic "CD1"
  @version 1
  @flag_lossless 0b0000_0001
  @flag_preserve 0b0000_0010

  @spec encode([{number(), number()}], keyword()) :: binary()
  def encode(points, opts) when is_list(points) do
    mode = Keyword.get(opts, :mode, :quantized)
    preserve = Keyword.get(opts, :preserve_order, false)
    bits = Keyword.get(opts, :bits, 16)

    if bits < 4 or bits > 24 do
      raise ArgumentError, "bits must be in 4..24, got #{inspect(bits)}"
    end

    indexed = Enum.with_index(points, fn {x, y}, i -> {x * 1.0, y * 1.0, i} end)

    {payload, flags, bits, bbox} =
      case mode do
        :lossless ->
          {encode_lossless(indexed, preserve), flag(true, preserve), 0, {0.0, 0.0, 0.0, 0.0}}

        :quantized ->
          {bin, bbox} = encode_quantized(indexed, bits, preserve)
          {bin, flag(false, preserve), bits, bbox}

        other ->
          raise ArgumentError, "Unknown mode #{inspect(other)}"
      end

    {xmin, xmax, ymin, ymax} = bbox
    n = length(points)

    <<@magic::binary, @version::8, flags::8, n::32, bits::8, xmin::float-32, xmax::float-32,
      ymin::float-32, ymax::float-32, payload::binary>>
  end

  @spec decode(binary()) :: {[float()], [float()]}
  def decode(
        <<@magic, @version::8, flags::8, n::32, bits::8, xmin::float-32, xmax::float-32,
          ymin::float-32, ymax::float-32, payload::binary>>
      ) do
    lossless? = (flags &&& @flag_lossless) != 0
    preserve? = (flags &&& @flag_preserve) != 0

    if n == 0 do
      {[], []}
    else
      raw = :zlib.uncompress(payload)

      if lossless? do
        decode_lossless(raw, n, preserve?)
      else
        decode_quantized(raw, n, bits, {xmin, xmax, ymin, ymax}, preserve?)
      end
    end
  end

  def decode(_), do: raise(ArgumentError, "invalid CloudDelta binary")

  defp flag(lossless?, preserve?) do
    if(lossless?, do: @flag_lossless, else: 0) |||
      if preserve?, do: @flag_preserve, else: 0
  end

  # --- lossless float32 (bitcast + delta + zlib) ---

  defp encode_lossless([], _preserve), do: :zlib.compress(<<>>)

  defp encode_lossless(indexed, preserve?) do
    ordered =
      indexed
      |> Enum.sort_by(fn {x, y, _i} -> {x, y} end)

    {xs, ys, orig} = unzip3(ordered)
    body = encode_u32_deltas(xs, ys) <> maybe_perm(orig, preserve?)
    :zlib.compress(body)
  end

  defp decode_lossless(raw, n, preserve?) do
    {xs, ys, rest} = decode_u32_deltas(raw, n)

    if preserve? do
      {perm, _} = decode_u32_list(rest, n)
      {apply_perm(xs, perm), apply_perm(ys, perm)}
    else
      {xs, ys}
    end
  end

  defp encode_u32_deltas([x0 | xs], [y0 | ys]) do
    px0 = bits_of(x0)
    py0 = bits_of(y0)

    {deltas, _, _} =
      Enum.zip(xs, ys)
      |> Enum.reduce({<<>>, px0, py0}, fn {x, y}, {acc, px, py} ->
        cx = bits_of(x)
        cy = bits_of(y)

        acc =
          acc <>
            uvarint(zigzag(to_signed32(wrap_sub(cx, px)))) <>
            uvarint(zigzag(to_signed32(wrap_sub(cy, py))))

        {acc, cx, cy}
      end)

    <<px0::32, py0::32, deltas::binary>>
  end

  defp decode_u32_deltas(<<x0::32, y0::32, rest::binary>>, n) do
    {xs, ys, rest} =
      Enum.reduce(1..(n - 1)//1, {[x0], [y0], rest}, fn _, {[px | _] = xs, [py | _] = ys, bin} ->
        {zx, bin} = take_uvarint(bin)
        {zy, bin} = take_uvarint(bin)
        cx = wrap_add(px, from_signed32(unzigzag(zx)))
        cy = wrap_add(py, from_signed32(unzigzag(zy)))
        {[cx | xs], [cy | ys], bin}
      end)

    {Enum.map(Enum.reverse(xs), &float_of/1), Enum.map(Enum.reverse(ys), &float_of/1), rest}
  end

  # --- quantized + Morton + integer delta ---

  defp encode_quantized([], _bits, _preserve) do
    {:zlib.compress(<<>>), {0.0, 0.0, 0.0, 0.0}}
  end

  defp encode_quantized(indexed, bits, preserve?) do
    {xs0, ys0, _} = unzip3(indexed)
    xmin = Enum.min(xs0)
    xmax = Enum.max(xs0)
    ymin = Enum.min(ys0)
    ymax = Enum.max(ys0)
    levels = (1 <<< bits) - 1

    quantized =
      Enum.map(indexed, fn {x, y, i} ->
        qx = quantize(x, xmin, xmax, levels)
        qy = quantize(y, ymin, ymax, levels)
        {qx, qy, i}
      end)

    ordered =
      if bits <= 16 do
        Enum.sort_by(quantized, fn {qx, qy, _} -> morton(qx, qy) end)
      else
        Enum.sort_by(quantized, fn {qx, qy, _} -> {qx, qy} end)
      end

    {qxs, qys, orig} = unzip3(ordered)
    body = encode_int_deltas(qxs, qys) <> maybe_perm(orig, preserve?)
    {:zlib.compress(body), {xmin, xmax, ymin, ymax}}
  end

  defp decode_quantized(raw, n, bits, {xmin, xmax, ymin, ymax}, preserve?) do
    levels = (1 <<< bits) - 1
    {qxs, qys, rest} = decode_int_deltas(raw, n)

    xs = Enum.map(qxs, &dequantize(&1, xmin, xmax, levels))
    ys = Enum.map(qys, &dequantize(&1, ymin, ymax, levels))

    if preserve? do
      {perm, _} = decode_u32_list(rest, n)
      {apply_perm(xs, perm), apply_perm(ys, perm)}
    else
      {xs, ys}
    end
  end

  defp encode_int_deltas([x0 | xs], [y0 | ys]) do
    header = uvarint(x0) <> uvarint(y0)

    {body, _, _} =
      Enum.zip(xs, ys)
      |> Enum.reduce({<<>>, x0, y0}, fn {x, y}, {acc, px, py} ->
        acc =
          acc <>
            uvarint(zigzag(x - px)) <>
            uvarint(zigzag(y - py))

        {acc, x, y}
      end)

    header <> body
  end

  defp decode_int_deltas(bin, n) do
    {x0, bin} = take_uvarint(bin)
    {y0, bin} = take_uvarint(bin)

    {xs, ys, rest} =
      Enum.reduce(1..(n - 1)//1, {[x0], [y0], bin}, fn _, {[px | _] = xs, [py | _] = ys, rest} ->
        {zx, rest} = take_uvarint(rest)
        {zy, rest} = take_uvarint(rest)
        {[px + unzigzag(zx) | xs], [py + unzigzag(zy) | ys], rest}
      end)

    {Enum.reverse(xs), Enum.reverse(ys), rest}
  end

  defp maybe_perm(_orig, false), do: <<>>
  defp maybe_perm(orig, true), do: Enum.reduce(orig, <<>>, fn i, acc -> acc <> uvarint(i) end)

  defp decode_u32_list(bin, n) do
    Enum.reduce(1..n, {[], bin}, fn _, {acc, rest} ->
      {v, rest} = take_uvarint(rest)
      {[v | acc], rest}
    end)
    |> then(fn {acc, rest} -> {Enum.reverse(acc), rest} end)
  end

  defp apply_perm(values, perm) do
    n = length(values)
    out = :array.new(n, default: nil)

    out =
      Enum.zip(values, perm)
      |> Enum.reduce(out, fn {v, i}, arr -> :array.set(i, v, arr) end)

    :array.to_list(out)
  end

  defp unzip3(list) do
    {a, b, c} =
      Enum.reduce(list, {[], [], []}, fn {x, y, i}, {xs, ys, is} ->
        {[x | xs], [y | ys], [i | is]}
      end)

    {Enum.reverse(a), Enum.reverse(b), Enum.reverse(c)}
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

  defp morton(x, y) do
    spread(x) ||| spread(y) <<< 1
  end

  defp spread(n) do
    n = n &&& 0xFFFF
    n = (n ||| n <<< 8) &&& 0x00FF00FF
    n = (n ||| n <<< 4) &&& 0x0F0F0F0F
    n = (n ||| n <<< 2) &&& 0x33333333
    (n ||| n <<< 1) &&& 0x55555555
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
end
