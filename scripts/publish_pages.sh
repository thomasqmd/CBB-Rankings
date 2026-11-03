#!/bin/sh
# Publish the rendered dashboard (only; the reports stay private) to GitHub Pages:
# https://thomasqmd.github.io/CBB-Rankings/
# Force-pushes docs/index.html (the dashboard; not the reports) as a single orphan commit on the gh-pages
# branch, so the daily 20 MB of rendered output never accumulates in the repo history.
# Run by scripts/daily_build.sh after a passing build; also safe to run by hand.
cd "$(dirname "$0")/.." || exit 1
remote=$(git remote get-url origin) || exit 1
[ -s docs/index.html ] || { echo "publish: docs/index.html missing"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# The dashboard only (self-contained: embed-resources). The reports stay private.
cp docs/index.html "$tmp/"
touch "$tmp/.nojekyll"

cd "$tmp" || exit 1
git init -q -b gh-pages
git add -A
git -c user.name="$(git -C "$OLDPWD" config user.name)" \
    -c user.email="$(git -C "$OLDPWD" config user.email)" \
    commit -q -m "Publish $(date '+%F %T')" || exit 1
git push -q -f "$remote" gh-pages && echo "publish: pushed $(du -sh . | cut -f1) to gh-pages"
