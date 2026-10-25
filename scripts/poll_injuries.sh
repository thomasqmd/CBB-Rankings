#!/bin/sh
# Archives ESPN's men's college basketball injury report once a day, for the days no build runs
# (a build archives the same file through fetch_espn_injuries()). ESPN keeps no history, so a day
# not archived is lost. Scheduled by scripts/com.cbb-rankings.injuries.plist (launchd).
cd "$(dirname "$0")/.." || exit 1
dir=data/raw/espn/injuries
mkdir -p "$dir"
f="$dir/injuries_$(date +%Y%m%d).json"
[ -s "$f" ] && exit 0
if curl -sf --max-time 60 "https://site.api.espn.com/apis/site/v2/sports/basketball/mens-college-basketball/injuries" -o "$f.part"; then
  mv "$f.part" "$f"
  echo "$(date '+%F %T') archived $f"
else
  rm -f "$f.part"
  echo "$(date '+%F %T') fetch failed" >&2
  exit 1
fi
