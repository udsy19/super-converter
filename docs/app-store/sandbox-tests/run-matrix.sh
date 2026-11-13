#!/bin/bash
# Runs each case of the matrix file ($2) through the sandboxed sconv of the harness app ($1). Fixtures are put inside the
# Store edition's container, or with FIXTURES_DIR=~/Downloads/<folder> outside it, in Downloads, which the app reads by
# its downloads.read-write entitlement (that exercises ToolStaging: bundled tools then get copies). Options may name
# @FIXTURES (replaced by the fixtures folder). Prints one TSV line per case.
set -uo pipefail
APP="$1"; CASES="$2"; GEN="$(cd "$(dirname "$0")/../../.." && pwd)/Tests/Corpus/generated"
C="$HOME/Library/Containers/com.udsy.superconverter.appstore/Data"
SCONV="$APP/Contents/MacOS/sconv"
FIX="${FIXTURES_DIR:-$C/fixtures}"
mkdir -p "$FIX" "$C/out"
printf 'family\tcase\texit\tresult\tdetail\n'
while IFS='|' read -r family src target opts; do
  [[ -z "$family" || "$family" == \#* ]] && continue
  name="$(basename "$src")"; stage="$FIX/$family"; mkdir -p "$stage"
  [[ "$src" = /* ]] && cp -R "$src" "$stage/" || cp -R "$GEN/$src" "$stage/"
  out="$C/out/$family/${name}-to-$target"; rm -rf "$out"; mkdir -p "$out"
  args=("$stage/$name" --to "$target" --out "$out")
  for o in $opts; do args+=(--option "${o//@FIXTURES/$FIX}"); done
  log="$(cd "$C" && timeout 300 "$SCONV" "${args[@]}" 2>&1)"; code=$?
  produced="$(find "$out" -type f ! -name '.*' | head -50)"
  count=$(printf '%s' "$produced" | grep -c . || true)
  bytes=$( [ -n "$produced" ] && find "$out" -type f ! -name '.*' -exec stat -f %z {} + | awk '{s+=$1} END {print s+0}' || echo 0)
  first="$(printf '%s\n' "$produced" | head -1)"
  kind="$( [ -n "$first" ] && file -b "$first" | cut -c1-60 )"
  if [ $code -eq 0 ] && [ "$count" -gt 0 ] && [ "$bytes" -gt 0 ]; then result=PASS; else result=FAIL; fi
  detail="$count file(s), $bytes B, $kind"
  [ $result = FAIL ] && detail="$detail | $(printf '%s' "$log" | tr '\n\t' '  ' | cut -c1-220)"
  printf '%s\t%s → %s\t%s\t%s\t%s\n' "$family" "$name" "$target" "$code" "$result" "$detail"
done < "$CASES"
