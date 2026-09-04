defmodule CloudDelta.Ply do
  @moduledoc false

  @doc """
  Load `{x, y, z}` vertices from an ASCII or binary PLY file.
  Extra vertex properties and face elements are ignored.
  """
  @spec load(Path.t()) :: [{float(), float(), float()}]
  def load(path) do
    {:ok, io} = File.open(path, [:read, :binary])

    try do
      {format, count, props} = read_header(io)
      read_vertices(io, format, count, props)
    after
      File.close(io)
    end
  end

  defp read_header(io) do
    ply = io |> IO.binread(:line) |> to_string() |> String.trim()

    if ply != "ply" do
      raise ArgumentError, "not a PLY file (got #{inspect(ply)})"
    end

    format = :ascii
    count = 0
    props = []
    in_vertex? = false
    done? = false

    {format, count, props} =
      Enum.reduce_while(
        Stream.repeatedly(fn -> IO.binread(io, :line) end),
        {format, count, props, in_vertex?, done?},
        fn
          :eof, acc ->
            {:halt, acc}

          line, {format, count, props, in_vertex?, _} ->
            line = line |> to_string() |> String.trim()

            cond do
              line == "end_header" ->
                {:halt, {format, count, props, in_vertex?, true}}

              String.starts_with?(line, "format ") ->
                {:cont, {parse_format(line), count, props, in_vertex?, false}}

              String.starts_with?(line, "element vertex ") ->
                n = line |> String.split() |> List.last() |> String.to_integer()
                {:cont, {format, n, [], true, false}}

              String.starts_with?(line, "element ") ->
                {:cont, {format, count, props, false, false}}

              in_vertex? and String.starts_with?(line, "property ") ->
                {:cont, {format, count, props ++ [parse_prop(line)], true, false}}

              true ->
                {:cont, {format, count, props, in_vertex?, false}}
            end
        end
      )
      |> then(fn {format, count, props, _, _} -> {format, count, props} end)

    if count <= 0, do: raise(ArgumentError, "PLY has no vertex element")
    {format, count, props}
  end

  defp parse_format("format ascii" <> _), do: :ascii
  defp parse_format("format binary_little_endian" <> _), do: :le
  defp parse_format("format binary_big_endian" <> _), do: :be

  defp parse_prop(line) do
    case String.split(line) do
      ["property", "list", _count_t, _item_t, name] ->
        {:list, name}

      ["property", type, name] ->
        {ply_type(type), name}

      _ ->
        raise ArgumentError, "unsupported PLY property: #{line}"
    end
  end

  defp ply_type(t) when t in ["char", "int8"], do: {:s, 1}
  defp ply_type(t) when t in ["uchar", "uint8"], do: {:u, 1}
  defp ply_type(t) when t in ["short", "int16"], do: {:s, 2}
  defp ply_type(t) when t in ["ushort", "uint16"], do: {:u, 2}
  defp ply_type(t) when t in ["int", "int32"], do: {:s, 4}
  defp ply_type(t) when t in ["uint", "uint32"], do: {:u, 4}
  defp ply_type(t) when t in ["float", "float32"], do: {:f, 4}
  defp ply_type(t) when t in ["double", "float64"], do: {:f, 8}
  defp ply_type(t), do: raise(ArgumentError, "unknown PLY type #{t}")

  defp read_vertices(_io, _format, 0, _props), do: []

  defp read_vertices(io, :ascii, count, props) do
    idx = xyz_indices(props)

    Stream.repeatedly(fn -> IO.binread(io, :line) end)
    |> Stream.take(count)
    |> Enum.map(fn line ->
      cols =
        line
        |> to_string()
        |> String.split()
        |> Enum.map(&parse_number/1)

      xyz(cols, idx)
    end)
  end

  defp read_vertices(io, endian, count, props) do
    idx = xyz_indices(props)
    record = vertex_record_size(props)

    for _ <- 1..count do
      bin = IO.binread(io, record)

      if bin == :eof or byte_size(bin) < record do
        raise ArgumentError, "truncated PLY vertex data"
      end

      vals = decode_record(bin, props, endian)
      xyz(vals, idx)
    end
  end

  defp xyz_indices(props) do
    names = Enum.map(props, fn {_t, name} -> name end)
    x = Enum.find_index(names, &(&1 == "x"))
    y = Enum.find_index(names, &(&1 == "y"))
    z = Enum.find_index(names, &(&1 == "z"))

    if is_nil(x) or is_nil(y) or is_nil(z) do
      raise ArgumentError, "PLY vertex element is missing x/y/z"
    end

    {x, y, z}
  end

  defp xyz(vals, {x, y, z}) do
    {Enum.at(vals, x) * 1.0, Enum.at(vals, y) * 1.0, Enum.at(vals, z) * 1.0}
  end

  defp parse_number(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> String.to_integer(s) * 1.0
    end
  end

  defp vertex_record_size(props) do
    Enum.reduce(props, 0, fn
      {:list, _}, _ -> raise ArgumentError, "list properties on vertices are not supported"
      {{_kind, size}, _}, acc -> acc + size
    end)
  end

  defp decode_record(bin, props, endian) do
    {vals, _} =
      Enum.map_reduce(props, bin, fn {{kind, size}, _name}, rest ->
        <<raw::binary-size(size), rest::binary>> = rest
        {decode_scalar(raw, kind, size, endian), rest}
      end)

    vals
  end

  defp decode_scalar(raw, :f, 4, :le) do
    <<v::float-little-32>> = raw
    v
  end

  defp decode_scalar(raw, :f, 4, :be) do
    <<v::float-big-32>> = raw
    v
  end

  defp decode_scalar(raw, :f, 8, :le) do
    <<v::float-little-64>> = raw
    v
  end

  defp decode_scalar(raw, :f, 8, :be) do
    <<v::float-big-64>> = raw
    v
  end

  defp decode_scalar(raw, :u, size, endian), do: decode_int(raw, size, endian, false)
  defp decode_scalar(raw, :s, size, endian), do: decode_int(raw, size, endian, true)

  defp decode_int(raw, size, :le, signed?) do
    bits = size * 8

    if signed?,
      do: match_int(raw, bits, :little, true),
      else: match_int(raw, bits, :little, false)
  end

  defp decode_int(raw, size, :be, signed?) do
    bits = size * 8
    if signed?, do: match_int(raw, bits, :big, true), else: match_int(raw, bits, :big, false)
  end

  defp match_int(raw, bits, :little, true) do
    <<v::signed-little-size(bits)>> = raw
    v
  end

  defp match_int(raw, bits, :little, false) do
    <<v::unsigned-little-size(bits)>> = raw
    v
  end

  defp match_int(raw, bits, :big, true) do
    <<v::signed-big-size(bits)>> = raw
    v
  end

  defp match_int(raw, bits, :big, false) do
    <<v::unsigned-big-size(bits)>> = raw
    v
  end

  @doc """
  Write an ASCII XYZ-only PLY (for Draco and other external tools).
  """
  @spec write_xyz(Path.t(), [{number(), number(), number()}]) :: :ok
  def write_xyz(path, points) do
    n = length(points)

    header = """
    ply
    format ascii 1.0
    element vertex #{n}
    property float x
    property float y
    property float z
    end_header
    """

    body =
      Enum.map(points, fn {x, y, z} ->
        "#{x} #{y} #{z}\n"
      end)

    File.write!(path, [header | body])
  end
end
