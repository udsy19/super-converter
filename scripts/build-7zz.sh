#!/bin/bash
# Builds the 7-Zip `7zz` command-line executable from the unmodified upstream source, universal (arm64 + x86_64),
# for macOS 14+.
#
#   scripts/build-7zz.sh build    download the pinned source (SHA-256 from Tools.lock), build both slices with the
#                                 upstream macOS makefiles, lipo into Vendor/Tools/7zz
#   scripts/build-7zz.sh fetch    download the published binaries instead (scripts/tools.sh fetch)
#
# Verify with `scripts/tools.sh check` and `scripts/tools.sh smoke`.
#
# Licence decision (docs/specs/formats.md §2): 7-Zip is LGPL-2.1+, with BSD-3 parts (LZFSE, zstd decoders) and the
# unRAR licence restriction on CPP/7zip/Compress/Rar*. We KEEP the unRAR decoder: Super Converter must extract RAR
# (RAR5 is an acceptance fixture) and the unRAR licence allows that ("may be used in any software to handle RAR
# archives ... but cannot be used to re-create the RAR compression algorithm"). `7zz` cannot write RAR, nothing here
# modifies the code, and THIRD_PARTY_NOTICES.md carries the restriction. Removing the unRAR code would only drop
# RAR reading; there is no licence need to, as long as the app stays free of charge (unRAR clause 3).
# Build notes: arm64 uses 7-Zip's assembler routines (clang); x86_64 builds the portable C code, because the x64
# assembly needs Asmc/JWasm, which the Command Line Tools do not ship (slower AES/SHA only on Intel).
# Needs: Command Line Tools (clang++, make, lipo), curl. Intermediates live in a temp dir removed on exit.
set -euo pipefail
source "$(dirname "$0")/tools-common.sh"

[[ "${1:-}" == fetch ]] && exec "$ROOT/scripts/tools.sh" fetch

build_arch() { # arch
    local arch="$1" mak
    case "$arch" in
        arm64)  mak="cmpl_mac_arm64.mak" ;;
        x86_64) mak="cmpl_mac_x64.mak" ;;
    esac
    local src="$WORK/$arch/src"
    log "[$arch] 7-Zip $SRC_VERSION"
    mkdir -p "$src"
    tar -xf "$SRC_PATH" -C "$src"   # the 7-Zip tarball has no top-level directory
    local dir="$src/CPP/7zip/Bundles/Alone2"
    (cd "$dir" && make -f "../../$mak" -j "$(sysctl -n hw.ncpu)" \
        MY_ARCH="-arch $arch -mmacosx-version-min=$DEPLOYMENT_TARGET" \
        CFLAGS_WARN_WALL= CFLAGS_WARN=-w CXX_WARN_FLAGS= >/dev/null)   # no -Werror: newer clangs add warnings

    cp "$dir/b/m_${arch/x86_64/x64}/7zz" "$WORK/$arch/7zz"
}

cmd_build() {
    make_work
    fetch_source 7zip
    local start=$SECONDS pids=() arch
    for arch in "${ARCHS[@]}"; do
        ( build_arch "$arch" ) > "$WORK/$arch.log" 2>&1 &
        pids+=($!)
    done
    local i failed=0
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            failed=1
            printf '%s\n' "--- ${ARCHS[$i]} build log (tail) ---" >&2
            tail -40 "$WORK/${ARCHS[$i]}.log" >&2
        fi
    done
    [[ $failed == 0 ]] || die "build failed"
    local slices=()
    for arch in "${ARCHS[@]}"; do slices+=("$WORK/$arch/7zz"); done
    lipo_binaries "$TOOLS_DIR/7zz" "${slices[@]}"
    log "Built in $((SECONDS - start)) s: 7zz $(lipo -archs "$TOOLS_DIR/7zz"), $(du -h "$TOOLS_DIR/7zz" | cut -f1)"
}

case "${1:-}" in
    build) cmd_build ;;
    *) die "usage: $0 build|fetch" ;;
esac
