#!/bin/bash
# Downloads GeoNames (cities with ≥1000 people, regions, countries) and rebuilds the server's
# bundled offline reverse-geocoding table. Only needed to refresh the data.
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp -d)
for f in cities1000.zip admin1CodesASCII.txt countryInfo.txt; do curl -sSfo "$tmp/$f" "https://download.geonames.org/export/dump/$f"; done
unzip -q -o "$tmp/cities1000.zip" -d "$tmp"
python3 build.py "$tmp" ../../server/Sources/PhotoCore/Places/geonames.deflate
rm -rf "$tmp"
