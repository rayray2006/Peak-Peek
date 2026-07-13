#!/usr/bin/env python3
"""Build the bundled global peak database (peaks_global.bin) from OSM via Overpass.

One-time, build-machine-only tool: the app never talks to Overpass for labels —
it reads the binary this script produces (see GlobalPeakDatabase.swift).

Subcommands:
  fetch  [--bbox S W N E]   Download all named natural=peak|volcano|saddle nodes.
                            Adaptive: starts on 8-degree cells and subdivides any
                            cell that hits the node cap or times out. Each cell is
                            cached under Tools/PeakDB/cache/ so the sweep is fully
                            resumable (rerun after any interruption).
  pack   [--out PATH]       Merge all cached cells into the binary.
  stats                     Print cache/pack progress.

Binary format (little-endian), consumed by GlobalPeakDatabase.swift:
  header:  "PKDB" | u16 version=2 | u16 reserved | u32 cellCount | u32 peakCount
  index:   cellCount * (u32 key | u32 offset | u32 count), sorted by key.
           key = (floor(lat)+90) * 360 + (floor(lon)+180); offset is relative to
           the start of the records region; count = records in that cell.
  records: per peak: i64 osmId | i32 latE7 | i32 lonE7 | i16 elevM | i16 promM |
           u8 kind | u8 nameLen | name UTF-8.  elevM/promM use -32768 = unknown.
           kind: 0 = summit (peak/volcano/hill), 1 = saddle/gap/pass — saddles
           are LOW points, so the app must not summit-snap them.
"""

import argparse
import http.client
import json
import os
import re
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.path.join(TOOL_DIR, "cache")
WATER_CACHE_DIR = os.path.join(TOOL_DIR, "cache_water")
DEFAULT_OUT = os.path.join(
    TOOL_DIR, "..", "..", "Sources", "App", "Resources", "peaks_global.bin")

ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]

NODE_CAP = 8000          # Overpass `out N` cap; hitting it means "subdivide"
BASE_CELL_DEG = 8.0      # starting cell size
MIN_CELL_DEG = 0.5       # never subdivide below this (accept the cap if reached)
SLEEP_BETWEEN = 1.0      # politeness delay between requests (seconds)
UNKNOWN = -32768


def cell_path(south, west, size, water=False):
    d = WATER_CACHE_DIR if water else CACHE_DIR
    return os.path.join(d, f"cell_{south:+08.3f}_{west:+08.3f}_{size:07.3f}.json")


def query_text(south, west, north, east, water=False):
    # Any name-ish key (name, name:en, name:de, …) so peaks tagged only with a
    # localized name aren't dropped; hills included for PeakVisor-scale coverage.
    bbox = f"({south},{west},{north},{east})"
    if water:
        # Named still-water bodies (rivers/canals excluded: a centroid label is
        # meaningless for long features). `out center` returns one point per
        # way/relation — no geometry transfer. This catches lakes GeoNames lacks
        # (e.g. young glacial tarns like Pea Soup Lake).
        sel = ('["natural"="water"]'
               '["water"!~"^(river|stream|canal|ditch|moat|wastewater)$"]'
               '[~"^name(:.+)?$"~"."]')
        return (
            "[out:json][timeout:120];"
            f"(node{sel}{bbox};way{sel}{bbox};relation{sel}{bbox};);"
            f"out center {NODE_CAP};"
        )
    return (
        "[out:json][timeout:120];"
        f'node["natural"~"^(peak|volcano|saddle|hill)$"][~"^name(:.+)?$"~"."]{bbox};'
        f"out {NODE_CAP};"
    )


def overpass(south, west, north, east, water=False):
    """Run one bbox query, rotating mirrors with backoff. Returns element list
    or raises TimeoutError to signal 'subdivide me'."""
    body = urllib.parse.urlencode({"data": query_text(south, west, north, east, water=water)}).encode()
    delay = 5
    for attempt in range(6):
        url = ENDPOINTS[attempt % len(ENDPOINTS)]
        try:
            req = urllib.request.Request(url, data=body,
                                         headers={"User-Agent": "mountainView-peakdb/1.0"})
            with urllib.request.urlopen(req, timeout=180) as resp:
                data = json.load(resp)
            remark = data.get("remark", "")
            if "timed out" in remark or "Query timed out" in remark:
                raise TimeoutError(remark)
            return data.get("elements", [])
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError,
                json.JSONDecodeError, ConnectionError, OSError,
                http.client.HTTPException) as e:   # IncompleteRead (truncated
                # chunked response) killed the Jul 2026 water sweep at ~50°N.
            if isinstance(e, TimeoutError):
                raise                      # dense cell: caller subdivides
            code = getattr(e, "code", None)
            if code in (429, 504, 502, 503) or code is None:
                print(f"    retry {attempt + 1} ({url.split('/')[2]}: {e}) in {delay}s")
                time.sleep(delay)
                delay = min(delay * 2, 120)
                continue
            raise
    raise RuntimeError(f"all mirrors failed for bbox {south},{west},{north},{east}")


def fetch_cell(south, west, size, stats, water=False):
    """Fetch one cell, subdividing on cap/timeout. Caches results per cell."""
    path = cell_path(south, west, size, water=water)
    if os.path.exists(path):
        stats["skipped"] += 1
        return
    north, east = south + size, west + size
    try:
        elements = overpass(south, west, min(north, 90), min(east, 180), water=water)
    except TimeoutError:
        elements = None                    # too dense to answer: subdivide
    if elements is not None and len(elements) < NODE_CAP:
        with open(path, "w") as f:
            json.dump(elements, f, separators=(",", ":"))
        stats["fetched"] += 1
        stats["peaks"] += len(elements)
        if elements:
            print(f"  cell {south:+.1f},{west:+.1f} x{size:g}: {len(elements)} peaks "
                  f"(total {stats['peaks']})")
        time.sleep(SLEEP_BETWEEN)
        return
    if size <= MIN_CELL_DEG:               # give up subdividing; accept capped data
        with open(path, "w") as f:
            json.dump(elements or [], f, separators=(",", ":"))
        stats["fetched"] += 1
        stats["peaks"] += len(elements or [])
        print(f"  WARNING cell {south:+.1f},{west:+.1f} x{size:g} capped at {NODE_CAP}")
        time.sleep(SLEEP_BETWEEN)
        return
    half = size / 2                        # subdivide into 4
    print(f"  subdividing {south:+.1f},{west:+.1f} x{size:g}")
    time.sleep(SLEEP_BETWEEN)
    for ds in (0, half):
        for dw in (0, half):
            fetch_cell(south + ds, west + dw, half, stats, water=water)


_NUM = re.compile(r"[-+]?\d[\d,]*(?:\.\d+)?")


def parse_meters(raw):
    """Parse an OSM ele/prominence tag ('2318', '2,318 m', '7602 ft')."""
    if not raw:
        return None
    m = _NUM.search(raw)
    if not m:
        return None
    try:
        value = float(m.group(0).replace(",", ""))
    except ValueError:
        return None
    if re.search(r"(ft|feet|')", raw, re.IGNORECASE):
        value *= 0.3048
    return value if -500 <= value <= 9000 else None


def cmd_fetch(args, water=False):
    os.makedirs(WATER_CACHE_DIR if water else CACHE_DIR, exist_ok=True)
    south0, west0, north0, east0 = args.bbox or (-90, -180, 90, 180)
    stats = {"fetched": 0, "skipped": 0, "peaks": 0}
    lat = south0
    while lat < north0:
        lon = west0
        while lon < east0:
            fetch_cell(lat, lon, BASE_CELL_DEG, stats, water=water)
            lon += BASE_CELL_DEG
        lat += BASE_CELL_DEG
        print(f"row {lat:+.0f} done: {stats}")
    print(f"fetch complete: {stats}")


def cmd_fetchwater(args):
    """Global sweep of named OSM still water (see query_text water=True).
    Separate resumable cache; merged into lakes_global.bin by `lakes`."""
    cmd_fetch(args, water=True)


def iter_cached_peaks():
    for name in sorted(os.listdir(CACHE_DIR)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(CACHE_DIR, name)) as f:
            for el in json.load(f):
                yield el


GEONAMES_DIR = os.path.join(TOOL_DIR, "geonames")
GEONAMES_TSV = os.path.join(GEONAMES_DIR, "geonames_peaks.tsv")
GEONAMES_URL = "https://download.geonames.org/export/dump/allCountries.zip"
# GeoNames feature codes worth labeling as summits.
GEONAMES_CODES = {"PK", "PKS", "MT", "MTS", "VLC", "HLL", "NTK", "NTKS"}


def geonames_zip():
    os.makedirs(GEONAMES_DIR, exist_ok=True)
    zip_path = os.path.join(GEONAMES_DIR, "allCountries.zip")
    if not os.path.exists(zip_path):
        print(f"downloading {GEONAMES_URL} (~400 MB)…")
        urllib.request.urlretrieve(GEONAMES_URL, zip_path + ".part")
        os.rename(zip_path + ".part", zip_path)
    return zip_path


# Lakes + reservoirs (NOT ponds/streams/marshes — label noise in a mountain app).
LAKE_CODES = {"LK", "LKN", "LKS", "LKC", "RSV", "LGN", "LGNS"}
LAKES_OUT = os.path.join(
    TOOL_DIR, "..", "..", "Sources", "App", "Resources", "lakes_global.bin")


def cmd_lakes(args):
    """Distill named lakes/reservoirs from the GeoNames dump into a PKDB binary
    (same format as peaks_global.bin, read by the same Swift reader). Ids are
    stored NEGATIVE → the app renders them as "gn-…" — GeoNames ids are unique
    across feature classes, so lake and peak ids can never collide. Elevation =
    the lake's surface elevation (GeoNames elevation, else its DEM sample)."""
    import zipfile
    lakes = {}
    with zipfile.ZipFile(geonames_zip()) as z, z.open("allCountries.txt") as raw:
        for line in (l.decode("utf-8", "replace") for l in raw):
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 18 or cols[6] != "H" or cols[7] not in LAKE_CODES:
                continue
            name = cols[1].strip()
            if not name:
                continue
            elev = parse_meters(cols[15]) or parse_meters(cols[16])
            lakes[-int(cols[0])] = (float(cols[4]), float(cols[5]), name, elev, None, 0)
    print(f"distilled {len(lakes)} GeoNames lakes/reservoirs")

    # Merge the OSM water sweep (cache_water/, from `fetchwater`): OSM has named
    # water GeoNames lacks (young tarns, local names). Same-name features within
    # ~1 km dedupe against GeoNames (keep the GeoNames entry — it has elevation);
    # the rest join with type-offset ids so node/way/relation ids can't collide
    # with each other or with peak node ids ("osm-<n>" strings stay unique).
    if os.path.isdir(WATER_CACHE_DIR):
        bucket = {}
        for gid, (lat, lon, name, _e, _p, _k) in lakes.items():
            bucket.setdefault((int(lat / 0.01), int(lon / 0.01), norm_name(name)), []).append(gid)
        offset = {"node": 0, "way": 20_000_000_000, "relation": 40_000_000_000}
        added = matched = 0
        for name_f in sorted(os.listdir(WATER_CACHE_DIR)):
            if not name_f.endswith(".json"):
                continue
            with open(os.path.join(WATER_CACHE_DIR, name_f)) as f:
                for el in json.load(f):
                    tags = el.get("tags") or {}
                    nm = (tags.get("name") or tags.get("name:en") or next(
                        (v for k, v in sorted(tags.items()) if k.startswith("name:")), "")).strip()
                    c = el.get("center") or el
                    lat, lon = c.get("lat"), c.get("lon")
                    if not nm or lat is None or lon is None:
                        continue
                    gy, gx, nn = int(lat / 0.01), int(lon / 0.01), norm_name(nm)
                    hit = any(bucket.get((gy + dy, gx + dx, nn))
                              for dy in (-1, 0, 1) for dx in (-1, 0, 1))
                    if hit:
                        matched += 1
                        continue
                    fid = el["id"] + offset.get(el.get("type", "node"), 0)
                    lakes[fid] = (lat, lon, nm, parse_meters(tags.get("ele")), None, 0)
                    added += 1
        print(f"osm water: {matched} matched GeoNames, {added} added → {len(lakes)} total")
    else:
        print("osm water: no cache_water/ (run `fetchwater` first) — GeoNames only")
    write_pkdb(lakes, os.path.abspath(args.out))


def cmd_geonames(_args):
    """Download the GeoNames dump once and distill it to a summit TSV:
    id, name, lat, lon, elevation. GeoNames' `dem` column (SRTM/ASTER sample)
    is populated for essentially every feature, so every row gets an elevation
    — this is what back-fills OSM peaks that have no `ele` tag."""
    import zipfile
    zip_path = geonames_zip()
    kept = 0
    with zipfile.ZipFile(zip_path) as z, z.open("allCountries.txt") as raw, \
            open(GEONAMES_TSV + ".part", "w") as out:
        for line in (l.decode("utf-8", "replace") for l in raw):
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 18 or cols[6] != "T" or cols[7] not in GEONAMES_CODES:
                continue
            gid, name, lat, lon = cols[0], cols[1].strip(), cols[4], cols[5]
            if not name:
                continue
            elev = parse_meters(cols[15]) or parse_meters(cols[16])  # elevation, then dem
            out.write(f"{gid}\t{name}\t{lat}\t{lon}\t{'' if elev is None else int(round(elev))}\n")
            kept += 1
    os.rename(GEONAMES_TSV + ".part", GEONAMES_TSV)
    print(f"kept {kept} GeoNames summits → {GEONAMES_TSV}")


def norm_name(name):
    return "".join(ch for ch in name.casefold() if ch.isalnum())


def cmd_pack(args):
    peaks = {}
    for el in iter_cached_peaks():
        osm_id = el.get("id")
        lat, lon = el.get("lat"), el.get("lon")
        tags = el.get("tags") or {}
        # Prefer the local name, then English, then any name:* variant.
        name = (tags.get("name") or tags.get("name:en") or next(
            (v for k, v in sorted(tags.items()) if k.startswith("name:")), "")).strip()
        if osm_id is None or lat is None or lon is None or not name:
            continue
        elev = parse_meters(tags.get("ele"))
        prom = parse_meters(tags.get("prominence"))
        kind = 1 if tags.get("natural") == "saddle" else 0
        peaks[osm_id] = (lat, lon, name, elev, prom, kind)
    print(f"packing {len(peaks)} unique OSM peaks")

    # Merge GeoNames (if distilled): same-name summits within ~2 km are treated
    # as the same peak — keep the OSM coord, back-fill missing elevation from
    # GeoNames. Everything else joins as a new peak under a NEGATIVE id (the
    # app renders ids < 0 as "gn-…"; OSM node ids are always positive).
    if os.path.exists(GEONAMES_TSV):
        bucket = {}                       # 0.02° grid of normalized OSM names
        for osm_id, (lat, lon, name, _e, _p, _k) in peaks.items():
            key = (int(lat / 0.02), int(lon / 0.02), norm_name(name))
            bucket.setdefault(key, []).append(osm_id)
        matched, added = 0, 0
        with open(GEONAMES_TSV) as f:
            for line in f:
                gid, name, lat, lon, elev = line.rstrip("\n").split("\t")
                lat, lon = float(lat), float(lon)
                elev = int(elev) if elev else None
                nn = norm_name(name)
                hit = None
                gy, gx = int(lat / 0.02), int(lon / 0.02)
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        for osm_id in bucket.get((gy + dy, gx + dx, nn), []):
                            hit = osm_id
                            break
                if hit is not None:
                    olat, olon, oname, oelev, oprom, okind = peaks[hit]
                    if oelev is None and elev is not None:
                        peaks[hit] = (olat, olon, oname, elev, oprom, okind)
                        matched += 1
                else:
                    peaks[-int(gid)] = (lat, lon, name, elev, None, 0)
                    added += 1
        print(f"geonames: back-filled {matched} elevations, added {added} peaks "
              f"→ {len(peaks)} total")
    else:
        print("geonames: no TSV (run the `geonames` subcommand first) — OSM only")

    write_pkdb(peaks, os.path.abspath(args.out))


def write_pkdb(features, out):
    """Write a {id: (lat, lon, name, elev, prom, kind)} dict as a PKDB v2 binary."""
    cells = {}
    for fid, (lat, lon, name, elev, prom, kind) in features.items():
        key = (int(lat // 1) + 90) * 360 + (int(lon // 1) + 180)
        cells.setdefault(key, []).append((fid, lat, lon, name, elev, prom, kind))
    records = bytearray()
    index = []
    for key in sorted(cells):
        offset = len(records)
        rows = cells[key]
        for fid, lat, lon, name, elev, prom, kind in rows:
            nm = name.encode("utf-8")[:255]
            records += struct.pack(
                "<qiihhBB", fid, int(round(lat * 1e7)), int(round(lon * 1e7)),
                UNKNOWN if elev is None else int(round(elev)),
                UNKNOWN if prom is None else int(round(prom)), kind, len(nm))
            records += nm
        index.append((key, offset, len(rows)))
    with open(out, "wb") as f:
        f.write(struct.pack("<4sHHII", b"PKDB", 2, 0, len(index), len(features)))
        for key, offset, count in index:
            f.write(struct.pack("<III", key, offset, count))
        f.write(records)
    print(f"wrote {out}: {os.path.getsize(out) / 1e6:.1f} MB, "
          f"{len(index)} cells, {len(features)} features")


def cmd_stats(_args):
    files = [f for f in os.listdir(CACHE_DIR) if f.endswith(".json")] \
        if os.path.isdir(CACHE_DIR) else []
    total = sum(1 for _ in iter_cached_peaks()) if files else 0
    print(f"{len(files)} cached cells, {total} peak elements")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch")
    f.add_argument("--bbox", nargs=4, type=float, metavar=("S", "W", "N", "E"))
    f.set_defaults(fn=cmd_fetch)
    k = sub.add_parser("pack")
    k.add_argument("--out", default=DEFAULT_OUT)
    k.set_defaults(fn=cmd_pack)
    g = sub.add_parser("geonames")
    g.set_defaults(fn=cmd_geonames)
    lk = sub.add_parser("lakes")
    lk.add_argument("--out", default=LAKES_OUT)
    lk.set_defaults(fn=cmd_lakes)
    fw = sub.add_parser("fetchwater")
    fw.add_argument("--bbox", nargs=4, type=float, metavar=("S", "W", "N", "E"))
    fw.set_defaults(fn=cmd_fetchwater)
    s = sub.add_parser("stats")
    s.set_defaults(fn=cmd_stats)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    sys.setrecursionlimit(10000)
    main()
