#!/usr/bin/env python3
"""Build the bundled global coarse DEM (horizon_global.bin) from ETOPO1.

One-time, build-machine-only tool. The app uses this for the FAR-HORIZON RING:
silhouettes of terrain beyond the 120 km raymarched tiers (see FarHorizon.swift).
A 3-arc-minute grid (max-pooled 3x from ETOPO1) keeps silhouette features
~1.5° wide at 150 km instead of the 5' grid's ~3° blobs; the whole planet
fits in ~52 MB. (POOL=5 was the original 18 MB tier — still a valid fallback
if bundle size ever needs to shrink.)

Input: etopo1_ice_g_i2.bin — ETOPO1 grid-registered int16 little-endian,
21601 x 10801, row 0 = lat +90, col 0 = lon -180, 1 arc-minute cells.

Output format (little-endian), read by FarHorizon.swift:
  "PPHZ" | u16 version=1 | u16 reserved | u32 cols | u32 rows |
  f32 cellDeg | i16[rows*cols] elevation meters (row 0 = lat +90, col 0 = -180,
  cell-registered: cell (r,c) covers [90 - (r+1)*cellDeg, 90 - r*cellDeg] lat).
  MAX-pooled from ETOPO1 (max preserves the ridge heights that form skylines;
  mean would shave summits by half a cell of relief). Ocean stays negative.

Usage: build_horizon_dem.py <etopo1_ice_g_i2.bin> <out.bin>
"""
import struct
import sys

import numpy as np

SRC_COLS, SRC_ROWS = 21601, 10801
POOL = 3                    # 1' -> 3' cells
OUT_COLS, OUT_ROWS = 7200, 3600


def main():
    src_path, out_path = sys.argv[1], sys.argv[2]
    data = np.fromfile(src_path, dtype="<i2")
    assert data.size == SRC_COLS * SRC_ROWS, f"unexpected size {data.size}"
    grid = data.reshape(SRC_ROWS, SRC_COLS)
    # Drop the duplicated wrap column/last row (grid-registered edges) so the
    # array is cleanly divisible for pooling: 21600 x 10800.
    grid = grid[: SRC_ROWS - 1, : SRC_COLS - 1]
    pooled = (
        grid.reshape(OUT_ROWS, POOL, OUT_COLS, POOL)
        .max(axis=(1, 3))
        .astype("<i2")
    )
    with open(out_path, "wb") as f:
        f.write(b"PPHZ")
        f.write(struct.pack("<HHIIf", 1, 0, OUT_COLS, OUT_ROWS, POOL / 60.0))
        f.write(pooled.tobytes())
    land = int((pooled > 0).sum())
    print(f"wrote {out_path}: {OUT_COLS}x{OUT_ROWS} {POOL}' cells, "
          f"{land} land cells, max {int(pooled.max())} m")


if __name__ == "__main__":
    main()
