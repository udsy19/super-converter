#!/bin/sh
# Renders every mockup in src/ to ../<name>.png (2×) with headless Google Chrome. Screens listed in DARK also get a
# -dark.png. Uses a throwaway Chrome profile next to this script; never touches the person's own Chrome profile.
# Usage: sh docs/mockups/render.sh [screen.html ...]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE="$HERE/.chrome-profile"
DARK="window-empty.html window-cards.html window-done.html"
cd "$HERE/src"
FILES="$*"; [ -z "$FILES" ] && FILES="$(ls *.html)"
shot() { # file, hash, out
  "$CHROME" --headless=new --disable-gpu --no-first-run --no-default-browser-check --allow-file-access-from-files \
    --user-data-dir="$PROFILE" --hide-scrollbars --force-device-scale-factor=2 --window-size=1280,820 \
    --virtual-time-budget=1500 --screenshot="$3" "file://$HERE/src/$1$2" >/dev/null 2>&1
  echo "rendered $3"
}
for f in $FILES; do
  base="${f%.html}"
  shot "$f" "" "$HERE/$base.png"
  case " $DARK " in *" $f "*) shot "$f" "#dark" "$HERE/$base-dark.png";; esac
done
