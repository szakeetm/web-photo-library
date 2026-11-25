"""Packs GeoNames data (CC BY 4.0, https://www.geonames.org) into the server's offline
reverse-geocoding table: server/Sources/PhotoCore/Places/geonames.deflate (raw deflate, UTF-8).

Input folder must contain cities1000.txt, admin1CodesASCII.txt and countryInfo.txt from
https://download.geonames.org/export/dump/ (see build.sh). Output sections:
  C\tCC\tcountry name
  A\tCC.admin1\tregion name
  P\tgeonameid\tname\tlat\tlon\tCC\tadmin1\tpopulation
"""
import os, sys, zlib

src = sys.argv[1]
out = sys.argv[2]
lines = []
for row in open(os.path.join(src, "countryInfo.txt"), encoding="utf-8"):
    if row.startswith("#"):
        continue
    f = row.rstrip("\n").split("\t")
    lines.append(f"C\t{f[0]}\t{f[4]}")
for row in open(os.path.join(src, "admin1CodesASCII.txt"), encoding="utf-8"):
    f = row.rstrip("\n").split("\t")
    lines.append(f"A\t{f[0]}\t{f[1]}")
n = 0
for row in open(os.path.join(src, "cities1000.txt"), encoding="utf-8"):
    f = row.rstrip("\n").split("\t")
    # 0 id, 1 name, 4 lat, 5 lon, 7 feature code, 8 country, 10 admin1, 14 population
    if f[7] in ("PPLX", "PPLH", "PPLQ", "PPLW"):  # sections of cities, historical, abandoned, destroyed
        continue
    lines.append(f"P\t{f[0]}\t{f[1]}\t{float(f[4]):.4f}\t{float(f[5]):.4f}\t{f[8]}\t{f[10]}\t{f[14] or 0}")
    n += 1
data = ("\n".join(lines) + "\n").encode("utf-8")
c = zlib.compressobj(9, zlib.DEFLATED, -15)
packed = c.compress(data) + c.flush()
open(out, "wb").write(packed)
print(f"{n} places, {len(data)/1e6:.1f} MB → {len(packed)/1e6:.1f} MB {out}")
