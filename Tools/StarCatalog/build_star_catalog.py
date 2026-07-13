#!/usr/bin/env python3
"""Build the bundled star catalog (stars.csv) from the HYG database.

One-time build tool: downloads HYG v4.1 (https://github.com/astronexus/HYG-Database,
CC BY-SA 4.0 — attribution required in-app), keeps every star to the magnitude
cutoff, resolves a display name for EVERY star, and writes the compact CSV that
CelestialSky loads at launch:

    name,raHours,decDeg,mag,colorIdx

Name preference: IAU proper name ("Vega") → Bayer + constellation ("α Lyr") →
Flamsteed + constellation ("61 Cyg") → catalog id ("HIP 91262").
colorIdx indexes CelestialSky.StarColor: 0 blueWhite, 1 white, 2 yellowWhite,
3 orange, 4 red — bucketed from the B–V color index.
"""

import csv
import io
import os
import urllib.request

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
HYG_URL = ("https://raw.githubusercontent.com/astronexus/HYG-Database/"
           "main/hyg/CURRENT/hygdata_v41.csv")
HYG_CACHE = os.path.join(TOOL_DIR, "hygdata_v41.csv")
OUT = os.path.join(TOOL_DIR, "..", "..", "Sources", "App", "Resources", "stars.csv")
MAG_LIMIT = 5.5           # naked-eye under decent skies; ~2.8k stars

GREEK = {
    "Alp": "α", "Bet": "β", "Gam": "γ", "Del": "δ", "Eps": "ε", "Zet": "ζ",
    "Eta": "η", "The": "θ", "Iot": "ι", "Kap": "κ", "Lam": "λ", "Mu": "μ",
    "Nu": "ν", "Xi": "ξ", "Omi": "ο", "Pi": "π", "Rho": "ρ", "Sig": "σ",
    "Tau": "τ", "Ups": "υ", "Phi": "φ", "Chi": "χ", "Psi": "ψ", "Ome": "ω",
}


def display_name(row):
    proper = row["proper"].strip()
    if proper and proper != "Sol":
        return proper
    bayer, con = row["bayer"].strip(), row["con"].strip()
    if bayer and con:
        # "Alp" → α, "The2" → θ2 (keep the component digit).
        head = bayer.rstrip("0123456789")
        digits = bayer[len(head):]
        if head in GREEK:
            return f"{GREEK[head]}{digits} {con}"
    flam = row["flam"].strip()
    if flam and con:
        return f"{flam} {con}"
    for key, tag in (("hip", "HIP"), ("hd", "HD"), ("hr", "HR")):
        if row[key].strip():
            return f"{tag} {row[key].strip()}"
    return None


def color_index(ci_raw):
    try:
        ci = float(ci_raw)
    except ValueError:
        return 1                      # unknown → white
    if ci < 0.00: return 0            # blueWhite
    if ci < 0.40: return 1            # white
    if ci < 0.90: return 2            # yellowWhite
    if ci < 1.40: return 3            # orange
    return 4                          # red


def main():
    if not os.path.exists(HYG_CACHE):
        print(f"downloading {HYG_URL} (~34 MB)…")
        urllib.request.urlretrieve(HYG_URL, HYG_CACHE + ".part")
        os.rename(HYG_CACHE + ".part", HYG_CACHE)
    out_rows = []
    with open(HYG_CACHE, newline="") as f:
        for row in csv.DictReader(f):
            try:
                mag = float(row["mag"])
                ra = float(row["ra"])
                dec = float(row["dec"])
            except ValueError:
                continue
            if mag > MAG_LIMIT or row["proper"].strip() == "Sol":
                continue
            name = display_name(row)
            if name is None:
                continue
            out_rows.append((mag, name, ra, dec, color_index(row["ci"])))
    out_rows.sort()                   # brightest first — nicer for debugging
    out = os.path.abspath(OUT)
    with open(out, "w") as f:
        for mag, name, ra, dec, ci in out_rows:
            assert "," not in name, name
            f.write(f"{name},{ra:.5f},{dec:.5f},{mag:.2f},{ci}\n")
    named = sum(1 for r in out_rows if not r[1][0].isascii() or " " not in r[1])
    print(f"wrote {out}: {len(out_rows)} stars ≤ mag {MAG_LIMIT}, "
          f"{os.path.getsize(out) / 1024:.0f} KB")


if __name__ == "__main__":
    main()
