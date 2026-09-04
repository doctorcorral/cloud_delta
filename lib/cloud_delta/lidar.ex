defmodule CloudDelta.Lidar do
  @moduledoc """
  Load automotive Velodyne bins and LAS/LAZ files for `CloudDelta.Compare`.
  """

  @spec load_kitti_bin(Path.t()) :: [{float(), float(), float()}]
  def load_kitti_bin(path) do
    for <<x::float-little-32, y::float-little-32, z::float-little-32,
          _i::float-little-32 <-
            File.read!(path)>> do
      {x, y, z}
    end
  end

  @spec load_las(Path.t()) :: [{float(), float(), float()}]
  def load_las(path) do
    python = python!()
    script = script!()
    dir = System.tmp_dir!()
    id = :erlang.unique_integer([:positive])
    out = Path.join(dir, "cd_las_#{id}.f64")

    {nstr, 0} = System.cmd(python, [script, "load", path, out], stderr_to_stdout: true)
    n = nstr |> String.trim() |> String.to_integer()
    bin = File.read!(out)
    File.rm(out)

    expected = n * 3 * 8

    if byte_size(bin) != expected do
      raise ArgumentError, "LAS dump size #{byte_size(bin)} != #{expected}"
    end

    for <<x::float-little-64, y::float-little-64, z::float-little-64 <- bin>> do
      {x, y, z}
    end
  end

  def python do
    [
      System.get_env("CLOUD_DELTA_PYTHON"),
      Path.expand(".tools/.venv/bin/python"),
      System.find_executable("python3")
    ]
    |> Enum.find(fn
      nil -> false
      path -> File.regular?(path)
    end)
  end

  def python! do
    python() || raise "Need Python with laspy/lazrs (see .tools/.venv)"
  end

  def script do
    Path.expand("scripts/laz_codec.py")
  end

  def script!, do: script()

  def laspy_available? do
    case python() do
      nil ->
        false

      py ->
        {_, status} =
          System.cmd(py, ["-c", "import laspy, lazrs"], stderr_to_stdout: true)

        status == 0 and File.regular?(script())
    end
  end
end
