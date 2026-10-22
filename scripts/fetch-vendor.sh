#!/bin/bash
# Downloads the vendor libraries pinned in Vendor.lock from this repository's Releases, checks each SHA-256 and
# unpacks it into Vendor/ (git-ignored). Built by scripts/build-vendor.sh; see that script for what each contains.
#
#   scripts/fetch-vendor.sh              fetch every pinned asset that is missing or differs from its pin
#   scripts/fetch-vendor.sh WebP AVIF    fetch only these xcframeworks (names without the suffix)
#   scripts/fetch-vendor.sh --force      fetch everything again
#
# Needs: gh (authenticated for the repository), shasum, ditto.
set -euo pipefail
source "$(dirname "$0")/tools-common.sh"
LOCK="$ROOT/Vendor.lock"
VENDOR="$ROOT/Vendor"

command -v gh >/dev/null || die "gh not found (brew install gh)"
[[ -f "$LOCK" ]] || die "$LOCK missing"

force=0
wanted=()
for arg in "$@"; do
    if [[ "$arg" == --force ]]; then force=1; else wanted+=("$arg"); fi
done

tag="$(lock_value release)"
[[ -n "$tag" ]] || die "Vendor.lock has no release line"

make_work
mkdir -p "$VENDOR"

fetched=0
while read -r kind asset sum; do
    [[ "$kind" == asset ]] || continue
    name="${asset%.xcframework.zip}"
    if [[ ${#wanted[@]} -gt 0 ]]; then
        match=0
        for w in "${wanted[@]}"; do [[ "$w" == "$name" ]] && match=1; done
        [[ $match == 1 ]] || continue
    fi
    # The pin is recorded next to the unpacked framework so an up-to-date copy is not downloaded again.
    stamp="$VENDOR/.$name.sha256"
    if [[ $force == 0 && -d "$VENDOR/$name.xcframework" && -f "$stamp" && "$(cat "$stamp")" == "$sum" ]]; then
        log "$name is up to date"
        continue
    fi
    log "Fetching $REPO $tag/$asset"
    gh release download "$tag" --repo "$REPO" --pattern "$asset" --dir "$WORK" --clobber
    verify_sha "$WORK/$asset" "$sum" "$asset"
    rm -rf "$VENDOR/$name.xcframework"
    ditto -x -k "$WORK/$asset" "$VENDOR"
    echo "$sum" > "$stamp"
    fetched=$((fetched + 1))
done < "$LOCK"

log "Vendor/ is ready ($fetched downloaded)"
