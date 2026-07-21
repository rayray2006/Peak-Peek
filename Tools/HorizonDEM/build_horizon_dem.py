#!/usr/bin/env python3
"""Build the bundled global coarse DEM (horizon_global.bin) for the far-horizon ring.

One-time, build-machine-only tool. The app uses this for the FAR-HORIZON RING:
silhouettes of terrain beyond the raymarched tiers (see FarHorizon.swift).
A 3-arc-minute grid keeps silhouette features ~1.5° wide at 150 km instead of
the 5' grid's ~3° blobs; the whole planet fits in ~52 MB. (POOL=5 was the
original 18 MB tier — still a valid fallback if bundle size ever needs to
shrink.)

Sources (choose one):
  etopo2022 (preferred, Jul 2026): ETOPO 2022 15-arc-second ice-surface tiles
      (netCDF-4, 15-degree tiles named "ETOPO_2022_v1_15s_<NW-corner>_surface.nc",
      from https://www.ngdc.noaa.gov/thredds/fileServer/global/ETOPO2022/15s/
      15s_surface_elev_netcdf/) max-pooled 12x, with the single 60-arc-second
      global file (same server, 60s directory) filling tiles skipped as pure
      ocean. 15" preserves summit maxima that ETOPO1's 1' cells had already
      smoothed away before pooling (Everest: 8586 m vs ETOPO1's ~8480).
  etopo1 (legacy): etopo1_ice_g_i2.bin — grid-registered int16 little-endian,
      21601 x 10801, row 0 = lat +90, col 0 = lon -180, 1-arc-minute cells,
      max-pooled 3x. (ETOPO1 int16 download ~325 MB, NOAA legacy archive.)

Catalog spiking (--peaks, on by default from the repo's peak DB): cell
averaging in ANY source grid understates sharp summits (even 15" cells average
Everest to ~8586 m), so prominent catalog peaks (prominence >= 1000 m from
peaks_global.bin — the same DB the app ships) raise their grid cell to the
TRUE summit elevation: max(cell, catalog). Implausible spikes (> 2500 m above
the pooled cell) are skipped as a datum/garbage guard.

Output format (little-endian), read by FarHorizon.swift — UNCHANGED:
  "PPHZ" | u16 version=1 | u16 reserved | u32 cols | u32 rows |
  f32 cellDeg | i16[rows*cols] elevation meters (row 0 = lat +90, col 0 = -180,
  cell-registered: cell (r,c) covers [90 - (r+1)*cellDeg, 90 - r*cellDeg] lat).
  MAX-pooled (max preserves the ridge heights that form skylines; mean would
  shave summits by half a cell of relief). Ocean stays negative.

Usage:
  build_horizon_dem.py etopo1 <etopo1_ice_g_i2.bin> <out.bin> [--peaks DB]
  build_horizon_dem.py etopo2022 <tiles_dir> <global_60s.nc> <out.bin> [--peaks DB]
  (etopo2022 needs h5py; --no-spike disables the catalog pass)
"""
import argparse
import os
import struct

import numpy as np

OUT_COLS, OUT_ROWS = 7200, 3600
CELL_DEG = 3.0 / 60.0
UNKNOWN = -32768
SPIKE_MIN_PROMINENCE = 1000
SPIKE_MAX_ABOVE_CELL = 2500
REPO_PEAKS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "..", "..", "Sources", "App", "Resources",
                          "peaks_global.bin")


def build_from_etopo1(src_path):
    SRC_COLS, SRC_ROWS, POOL = 21601, 10801, 3
    data = np.fromfile(src_path, dtype="<i2")
    assert data.size == SRC_COLS * SRC_ROWS, f"unexpected size {data.size}"
    grid = data.reshape(SRC_ROWS, SRC_COLS)
    # Drop the duplicated wrap column/last row (grid-registered edges) so the
    # array is cleanly divisible for pooling: 21600 x 10800.
    grid = grid[: SRC_ROWS - 1, : SRC_COLS - 1]
    return (grid.reshape(OUT_ROWS, POOL, OUT_COLS, POOL)
                .max(axis=(1, 3)).astype(np.int32))


def tile_token(north, west):
    lat = f"N{north:02d}" if north >= 0 else f"S{-north:02d}"
    lon = f"E{west:03d}" if west >= 0 else f"W{-west:03d}"
    return lat + lon


def read_nc_z(path):
    import h5py
    with h5py.File(path, "r") as f:
        z = np.asarray(f["z"][...], dtype=np.float32)
        lat = f["lat"]
        ascending = lat[0] < lat[-1]
    z[z <= -99998] = -100          # fill value -> deep ocean, harmless
    if ascending:                   # netCDF rows run south->north; we want +90 first
        z = z[::-1, :]
    return z


def pool_max(a, pool):
    r, c = a.shape
    return a.reshape(r // pool, pool, c // pool, pool).max(axis=(1, 3))


def build_from_etopo2022(tiles_dir, global60_path):
    # Base layer: the 60" global file (21600 x 10800) pooled 3x -> 3'. Covers
    # every cell (poles, open ocean); 15" land tiles overwrite it below.
    base = read_nc_z(global60_path)
    assert base.shape == (10800, 21600), f"60s grid shape {base.shape}"
    out = pool_max(base, 3).astype(np.float32)
    assert out.shape == (OUT_ROWS, OUT_COLS)

    used = 0
    for north in range(90, -76, -15):   # tile tokens N90 … S75 (NW corners)
        for west in range(-180, 180, 15):
            path = os.path.join(
                tiles_dir, f"ETOPO_2022_v1_15s_{tile_token(north, west)}_surface.nc")
            if not os.path.exists(path):
                continue
            z = read_nc_z(path)                     # 3600 x 3600, row 0 = north
            assert z.shape == (3600, 3600), f"{path}: {z.shape}"
            block = pool_max(z, 12)                 # 15" -> 3' (300 x 300)
            r0 = int(round((90 - north) / 15.0)) * 300
            c0 = int(round((west + 180) / 15.0)) * 300
            out[r0:r0 + 300, c0:c0 + 300] = block
            used += 1
    print(f"etopo2022: {used} x 15\" tiles over the 60\" base")
    return np.rint(out).astype(np.int32)


def iter_catalog_peaks(db_path):
    with open(db_path, "rb") as f:
        blob = f.read()
    magic, = struct.unpack_from("<4s", blob, 0)
    assert magic == b"PKDB", "not a PKDB file"
    ver, _res, cell_count, peak_count = struct.unpack_from("<HHII", blob, 4)
    assert ver == 2, f"unexpected PKDB version {ver}"
    off = 16 + cell_count * 12                     # header + cell index
    rec = struct.Struct("<qiihhBB")
    for _ in range(peak_count):
        _osm, lat_e7, lon_e7, elev, prom, kind, name_len = rec.unpack_from(blob, off)
        off += rec.size + name_len
        yield lat_e7 / 1e7, lon_e7 / 1e7, elev, prom, kind


def spike_catalog(grid, db_path):
    applied = skipped_implausible = 0
    for lat, lon, elev, prom, kind in iter_catalog_peaks(db_path):
        if kind != 0 or elev == UNKNOWN or elev <= 0:
            continue
        if prom == UNKNOWN or prom < SPIKE_MIN_PROMINENCE:
            continue
        r = min(OUT_ROWS - 1, max(0, int((90.0 - lat) / CELL_DEG)))
        c = int((lon + 180.0) / CELL_DEG) % OUT_COLS
        cell = grid[r, c]
        if elev <= cell:
            continue
        if elev - cell > SPIKE_MAX_ABOVE_CELL:
            skipped_implausible += 1
            continue
        grid[r, c] = elev
        applied += 1
    print(f"catalog spikes: {applied} applied, "
          f"{skipped_implausible} skipped (implausible vs pooled cell)")
    return grid


def write_output(grid, out_path):
    pooled = np.clip(grid, -32768, 32767).astype("<i2")
    with open(out_path, "wb") as f:
        f.write(b"PPHZ")
        f.write(struct.pack("<HHIIf", 1, 0, OUT_COLS, OUT_ROWS, CELL_DEG))
        f.write(pooled.tobytes())
    land = int((pooled > 0).sum())
    print(f"wrote {out_path}: {OUT_COLS}x{OUT_ROWS} 3' cells, "
          f"{land} land cells, max {int(pooled.max())} m")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["etopo1", "etopo2022"])
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("--peaks", default=REPO_PEAKS)
    ap.add_argument("--no-spike", action="store_true")
    args = ap.parse_args()

    if args.mode == "etopo1":
        src, out_path = args.inputs
        grid = build_from_etopo1(src)
    else:
        tiles_dir, global60, out_path = args.inputs
        grid = build_from_etopo2022(tiles_dir, global60)

    if not args.no_spike:
        if os.path.exists(args.peaks):
            grid = spike_catalog(grid, args.peaks)
        else:
            print(f"WARNING: peak DB not found at {args.peaks}; no spiking")

    write_output(grid, out_path)


if __name__ == "__main__":
    main()
