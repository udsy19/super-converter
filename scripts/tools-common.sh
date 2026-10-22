# Shared by scripts/build-ffmpeg.sh, scripts/build-7zz.sh and scripts/tools.sh (sourced, not run).
# Pins live in Tools.lock. Intermediates live in a temp dir that is removed on exit.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/Tools.lock"
REPO="udsy19/super-converter"
DEPLOYMENT_TARGET="14.0"
read -r -a ARCHS <<<"${TOOLS_ARCHS:-arm64 x86_64}"   # TOOLS_ARCHS=arm64 for a quick single-slice dev build
TOOLS_DIR="$ROOT/Vendor/Tools"          # installed binaries (ffmpeg, ffprobe, 7zz) + Licenses/
DIST="$ROOT/dist"
SRC_CACHE="$DIST/tools-sources"         # verified upstream tarballs; published as the LGPL source asset
BINARIES=(ffmpeg ffprobe 7zz)

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

WORK=""
cleanup() {
    local pids; pids="$(jobs -p)"
    [[ -n "$pids" ]] && kill $pids 2>/dev/null
    [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
    return 0
}
trap cleanup EXIT
make_work() { WORK="$(mktemp -d "${TMPDIR:-/tmp}/sc-tools.XXXXXX")"; }

# lock_source <id>: sets SRC_VERSION SRC_FILE SRC_SHA SRC_URL
lock_source() {
    local line
    line="$(awk -v id="$1" '$1 == "source" && $2 == id { print; exit }' "$LOCK")"
    [[ -n "$line" ]] || die "no source '$1' in Tools.lock"
    read -r _ _ SRC_VERSION SRC_FILE SRC_SHA SRC_URL <<<"$line"
}
lock_value() { awk -v k="$1" '$1 == k { print $2; exit }' "$LOCK"; }       # lock_value release
lock_asset() { awk -v n="$1" '$1 == "asset" && $2 == n { print $3; exit }' "$LOCK"; }
lock_set() { # lock_set <key> <name|-> <value>: replace or append a `release`/`asset` line
    local key="$1" name="$2" value="$3" tmp="$WORK/lock.new"
    awk -v k="$key" -v n="$name" '!($1 == k && (n == "-" || $2 == n))' "$LOCK" > "$tmp"
    if [[ "$name" == "-" ]]; then echo "$key $value" >> "$tmp"; else echo "$key $name $value" >> "$tmp"; fi
    cp "$tmp" "$LOCK"
}

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
verify_sha() { # file sha256 label
    local got; got="$(sha256_of "$1")"
    [[ "$got" == "$2" ]] || die "SHA-256 mismatch for $3: expected $2, got $got"
}

# fetch_source <id>: download (once) into SRC_CACHE, verify against Tools.lock; sets SRC_PATH
fetch_source() {
    lock_source "$1"
    SRC_PATH="$SRC_CACHE/$SRC_FILE"
    mkdir -p "$SRC_CACHE"
    if [[ ! -f "$SRC_PATH" ]] || [[ "$(sha256_of "$SRC_PATH")" != "$SRC_SHA" ]]; then
        log "Downloading $SRC_FILE"
        curl -fsSL --retry 3 -o "$SRC_PATH.part" "$SRC_URL"
        mv "$SRC_PATH.part" "$SRC_PATH"
    fi
    verify_sha "$SRC_PATH" "$SRC_SHA" "$SRC_FILE"
}

# unpack_source <id> <dest>: extract the verified tarball; sets SRC_DIR to its single top-level directory
unpack_source() {
    fetch_source "$1"
    mkdir -p "$2"
    tar -xf "$SRC_PATH" -C "$2"
    SRC_DIR="$(find "$2" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [[ -d "$SRC_DIR" ]] || die "$SRC_FILE has no top-level directory"
}

# lipo_binaries <out> <per-arch binary...>: universal when two slices, plain copy for one
lipo_binaries() {
    local out="$1"; shift
    mkdir -p "$(dirname "$out")"
    if [[ $# -gt 1 ]]; then lipo -create "$@" -output "$out"; else cp "$1" "$out"; fi
    strip -x "$out"
    codesign --force --sign - "$out" >/dev/null 2>&1   # ad hoc; the app build re-signs with its identity
}
