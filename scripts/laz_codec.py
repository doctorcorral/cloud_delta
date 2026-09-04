#!/usr/bin/env python3
"""LAZ helper for CloudDelta.Compare.

encode-ints: write a LAZ from packed little-endian int32 xyz (same grid as
CloudDelta quantized mode). load: dump a LAS/LAZ to packed little-endian
float64 xyz and print the point count.
"""

from __future__ import annotations

import argparse
import os
import sys
import time

import laspy
import numpy as np


def encode_ints(path_in: str, path_out: str) -> None:
    raw = np.fromfile(path_in, dtype="<i4")
    if raw.size % 3 != 0:
        raise SystemExit(f"int32 file length {raw.size} is not a multiple of 3")
    pts = raw.reshape(-1, 3)
    header = laspy.LasHeader(point_format=0, version="1.2")
    header.offsets = np.zeros(3, dtype=np.float64)
    header.scales = np.ones(3, dtype=np.float64)
    las = laspy.LasData(header)
    las.X = pts[:, 0]
    las.Y = pts[:, 1]
    las.Z = pts[:, 2]
    t0 = time.perf_counter()
    las.write(path_out)
    ms = (time.perf_counter() - t0) * 1000.0
    print(f"{os.path.getsize(path_out)} {ms:.4f}")


def load(path_in: str, path_out: str) -> None:
    las = laspy.read(path_in)
    xyz = np.column_stack(
        [
            np.asarray(las.x, dtype=np.float64),
            np.asarray(las.y, dtype=np.float64),
            np.asarray(las.z, dtype=np.float64),
        ]
    )
    xyz.tofile(path_out)
    print(len(xyz))


def decode(path_in: str) -> None:
    t0 = time.perf_counter()
    las = laspy.read(path_in)
    _ = np.column_stack(
        [
            np.asarray(las.x, dtype=np.float64),
            np.asarray(las.y, dtype=np.float64),
            np.asarray(las.z, dtype=np.float64),
        ]
    )
    ms = (time.perf_counter() - t0) * 1000.0
    print(f"{len(las.x)} {ms:.4f}")


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    enc = sub.add_parser("encode-ints")
    enc.add_argument("ints")
    enc.add_argument("out")

    ld = sub.add_parser("load")
    ld.add_argument("src")
    ld.add_argument("out")

    dec = sub.add_parser("decode")
    dec.add_argument("src")

    args = parser.parse_args(argv)
    if args.cmd == "encode-ints":
        encode_ints(args.ints, args.out)
    elif args.cmd == "decode":
        decode(args.src)
    else:
        load(args.src, args.out)


if __name__ == "__main__":
    main(sys.argv[1:])
