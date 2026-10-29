#!/usr/bin/env bash
# Downloads the external corpus of the quality bench (quality §9) into Tests/Corpus/external/ (git-ignored). Opt-in: nothing
# in the tests, the self-test or the bench calls it, and the bench only skips cases whose fixture is missing.
#
#   scripts/fetch-corpus.sh                 fetch every entry of Tests/Corpus/corpus.lock not already present and verified
#   scripts/fetch-corpus.sh --only <id>...  fetch just these entries
#   scripts/fetch-corpus.sh --list          show the entries and whether each is present
#   scripts/fetch-corpus.sh --pin <url>     download one URL to a temporary file and print its lock line (hash included)
#
# Every download is checked against the SHA-256 in the lock; a mismatch deletes the file and fails. Sources are limited to those
# whose licence permits it (see the lock's header).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/Tests/Corpus/corpus.lock"
DEST="$ROOT/Tests/Corpus/external"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

entries() { grep -v '^[[:space:]]*#' "$LOCK" | grep -v '^[[:space:]]*$'; }

list() {
    entries | while read -r id path hash url licence extract; do
        if [[ -f "$DEST/$path" && "$(sha256 "$DEST/$path")" == "$hash" ]]; then state="present"; else state="missing"; fi
        printf '%-18s %-9s %-26s %s\n' "$id" "$state" "$licence" "$path"
    done
}

fetch() {
    local id="$1" path="$2" hash="$3" url="$4" extract="${5:-}"
    local target="$DEST/$path"
    if [[ -f "$target" && "$(sha256 "$target")" == "$hash" ]]; then echo "ok       $id (already present)"; return; fi
    mkdir -p "$(dirname "$target")"
    local part="$target.part"
    echo "fetching $id"
    curl --fail --silent --show-error --location --retry 3 --output "$part" "$url"
    if [[ "$(sha256 "$part")" != "$hash" ]]; then
        rm -f "$part"
        echo "error: $id does not match its pinned SHA-256" >&2
        exit 1
    fi
    mv "$part" "$target"
    if [[ "$extract" == "extract" ]]; then
        tar -xzf "$target" -C "$(dirname "$target")"
    elif [[ "$extract" == "uudecode" ]]; then
        uudecode -o "${target%.uu}" "$target"
    fi
    echo "ok       $id"
}

case "${1:-}" in
    --list) list ;;
    --pin)
        [[ $# -eq 2 ]] || { echo "usage: $0 --pin <url>" >&2; exit 64; }
        tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
        curl --fail --silent --show-error --location --output "$tmp" "$2"
        name="$(basename "$2")"
        printf '%s  <folder>/%s  %s  %s  <licence>\n' "<id>" "$name" "$(sha256 "$tmp")" "$2"
        ;;
    --only)
        shift
        [[ $# -gt 0 ]] || { echo "usage: $0 --only <id>..." >&2; exit 64; }
        for wanted in "$@"; do
            line="$(entries | awk -v id="$wanted" '$1 == id')"
            [[ -n "$line" ]] || { echo "error: no entry $wanted in $LOCK" >&2; exit 64; }
            read -r id path hash url licence extract <<<"$line"
            fetch "$id" "$path" "$hash" "$url" "$extract"
        done
        ;;
    "")
        entries | while read -r id path hash url licence extract; do fetch "$id" "$path" "$hash" "$url" "${extract:-}"; done
        ;;
    *) echo "usage: $0 [--list | --only <id>... | --pin <url>]" >&2; exit 64 ;;
esac
