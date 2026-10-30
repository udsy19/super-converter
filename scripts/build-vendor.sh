#!/bin/bash
# Builds, verifies and publishes the third-party libraries Super Converter links (docs/specs/formats.md §3.3,
# docs/ARCHITECTURE.md "Bundled libraries" and WP0b). Every library is built from pinned upstream source
# (SHA-256 checked), as a static universal (arm64 + x86_64) library for macOS 14, and packed as an xcframework
# assembled by hand (the Command Line Tools have no xcodebuild). LibRaw (LGPL) is the one dynamic library.
#
#   scripts/build-vendor.sh build [LIB...|all]   build into Vendor/<Name>.xcframework and dist/<Name>.xcframework.zip
#   scripts/build-vendor.sh verify [LIB...|all]  link and run scripts/vendor/smoke/<lib>.swift against Vendor/ on
#                                                both slices (x86_64 runs under Rosetta)
#   scripts/build-vendor.sh licenses             download every pinned source and run the licence allow-list check
#   scripts/build-vendor.sh notices [write|check]   print the vendor section of THIRD_PARTY_NOTICES.md (from Vendor/),
#                                                write it between its markers, or fail if the file is stale
#   scripts/build-vendor.sh release [TAG]        upload dist/ to a GitHub PRERELEASE (default tag vendor-<date>) and
#                                                write the SHA-256 pins to Vendor.lock
#   scripts/fetch-vendor.sh                      download the pinned release assets into Vendor/ (see that script)
#
# LIB is one of: webp avif archive xls woff2 unalz libraw.
#
#   webp     WebP.xcframework     libwebp (+ demux, mux, sharpyuv)                          BSD-3-Clause
#   avif     AVIF.xcframework     libavif + SVT-AV1 (lossy encode) + libaom (lossless and 4:4:4 encode) + dav1d (decode)
#                                                                                          BSD-2-Clause, BSD-3-Clause-Clear, BSD-2-Clause, BSD-2-Clause
#   archive  Archive.xcframework  libarchive + liblzma + zstd + lz4 (zlib, bzip2, iconv from the SDK)   BSD-2-Clause, 0BSD, BSD-3-Clause, BSD-2-Clause
#   xls      XLS.xcframework      libxls                                                    BSD-2-Clause
#   woff2    WOFF2.xcframework    google/woff2 + Brotli + a C shim (scripts/vendor/shims)   MIT
#   unalz    UnALZ.xcframework    unalz + its bzip2 variant (symbols renamed) + a C shim    Zlib, bzip2-1.0.6
#   libraw   LibRaw.xcframework   libraw_r.dylib with the X3F tools                         LGPL-2.1 (dynamic only), BSD-3-Clause X3F code
#
# Consuming (Package.swift): every xcframework is a `.binaryTarget(path: "Vendor/<Name>.xcframework")` whose module map
# names the module (`import WebP`, `import AVIF`, `import Archive`, `import XLS`, `import WOFF2`, `import UnALZ`,
# `import LibRaw`) and autolinks the system libraries it needs (libz, libbz2, libiconv, libc++).
#   - x86_64 with the Command Line Tools: pass `-Xswiftc -runtime-compatibility-version -Xswiftc none` (the CLT ship the
#     back-deployment libraries for arm64 only; see Super PDF's scripts/build-app.sh).
#   - libarchive converts entry names through the C locale: call setlocale(LC_ALL, "en_US.UTF-8") before using names
#     that are not ASCII.
#   - AVIF: SVT-AV1 encodes 4:2:0 only, so lossless and 4:4:4 go through libaom (encoder only; dav1d decodes);
#     libavif is built without libyuv (its own, slower, conversions).
#   - LibRaw is dynamic: scripts/build-app.sh copies libraw_r.dylib into Contents/Frameworks and signs it with the app's
#     identity (its install name is @rpath/libraw_r.dylib). JPEG-compressed (lossy) DNG is not decoded by it.
#   - WOFF2 and UnALZ export small C interfaces (scripts/vendor/shims/*.h) instead of their C++ classes.
#
# Licence policy (formats §2): the allow-list below is enforced for every component before it is built; anything
# else (GPL, AGPL, unknown) fails the build. LGPL is accepted only for a dynamic library.
#
# Needs: Command Line Tools (clang, libtool, lipo, swift, vtool), cmake >= 3.16, python3 (for meson/ninja in a
# throw-away venv and for the smoke fixtures), curl, shasum, ditto; gh for release. Rosetta for the x86_64 smoke run.
# Intermediates live in a temp directory that is removed on exit. Keep at least 10 GB free.
set -euo pipefail

source "$(dirname "$0")/tools-common.sh"   # log/die, temp dir, SHA-256 checks, tarball cache, lock file helpers, host tools
LOCK="$ROOT/Vendor.lock"                   # this script's pins (tools-common.sh defaults to Tools.lock)
SRC_CACHE="$DIST/vendor-sources"           # verified upstream tarballs (LibRaw's is published next to the binary)
ARCHS=(arm64 x86_64)
MIN_FREE_GB=10
ALLOWED_SPDX="MIT BSD-2-Clause BSD-3-Clause BSD-3-Clause-Clear Apache-2.0 ISC Zlib 0BSD bzip2-1.0.6 LGPL-2.1-only"
DYNAMIC_ONLY_SPDX="LGPL-2.1-only"
VENDOR="$ROOT/Vendor"
VENDOR_SCRIPTS="$ROOT/scripts/vendor"

# What is built from each pinned source (version, URL and SHA-256 are in Vendor.lock).
# id | SPDX licence | licence files inside the source's top-level directory (':' separated) | library it ships in
COMPONENTS=(
"libwebp|BSD-3-Clause|COPYING:PATENTS|webp"
"libavif|BSD-2-Clause|LICENSE|avif"
"svtav1|BSD-3-Clause-Clear|LICENSE.md:PATENTS.md|avif"
"libaom|BSD-2-Clause|LICENSE:PATENTS:third_party/fastfeat/LICENSE:third_party/vector/LICENSE:third_party/x86inc/LICENSE|avif"
"dav1d|BSD-2-Clause|COPYING|avif"
"libarchive|BSD-2-Clause|COPYING|archive"
"xz|0BSD|COPYING.0BSD|archive"
"zstd|BSD-3-Clause|LICENSE|archive"
"lz4|BSD-2-Clause|lib/LICENSE|archive"
"libxls|BSD-2-Clause|LICENSE|xls"
"woff2|MIT|LICENSE|woff2"
"brotli|MIT|LICENSE|woff2"
"unalz|Zlib|readme.txt|unalz"
"bzip2|bzip2-1.0.6|LICENSE|unalz"
"libraw|LGPL-2.1-only|LICENSE.LGPL:COPYRIGHT|libraw"
)

# Library -> xcframework name (the components in each are the COMPONENTS rows naming it).
LIBS=(webp avif archive xls woff2 unalz libraw)
xcf_name() { case "$1" in webp) echo WebP;; avif) echo AVIF;; archive) echo Archive;; xls) echo XLS;; woff2) echo WOFF2;; unalz) echo UnALZ;; libraw) echo LibRaw;; *) die "unknown library '$1'";; esac; }
lib_kind() { [[ "$1" == libraw ]] && echo dylib || echo static; }

comp_row() { # id -> its COMPONENTS row
    local row
    for row in "${COMPONENTS[@]}"; do [[ "${row%%|*}" == "$1" ]] && { echo "$row"; return; }; done
    die "no component '$1'"
}
comp_field() { comp_row "$1" | cut -d'|' -f"$2"; }   # id index(1-based): 2 SPDX, 3 licence files, 4 library
components_of() { # lib -> component ids
    local row
    for row in "${COMPONENTS[@]}"; do
        [[ "${row##*|}" == "$1" ]] && echo "${row%%|*}"
    done
    return 0
}
ver() { lock_source "$1"; printf '%s' "$SRC_VERSION"; }   # id -> pinned version

# Unpacks a pinned source (once) and prints its top-level directory.
srcdir() {
    local dest="$WORK/src/$1"
    [[ -d "$dest" ]] || unpack_source "$1" "$dest"
    find "$dest" -mindepth 1 -maxdepth 1 -type d | head -1
}

# ---------------------------------------------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------------------------------------------
setup_env() {
    [[ -n "$WORK" ]] && return 0
    command -v cmake >/dev/null || die "cmake not found (brew install cmake)"
    local free_gb
    free_gb="$(df -g / | awk 'NR==2 {print $4}')"
    [[ "$free_gb" -ge "$MIN_FREE_GB" ]] || die "only $free_gb GB free on /, need $MIN_FREE_GB"
    make_work
    mkdir -p "$WORK/bin" "$WORK/src" "$WORK/logs" "$WORK/stage"
    ln -s "$(command -v cmake)" "$WORK/bin/cmake"
    # A clean PATH: nothing from Homebrew can leak into configure scripts or the produced libraries.
    export PATH="$WORK/bin:$WORK/host/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
    JOBS="$(sysctl -n hw.ncpu)"
    export JOBS
}

# nasm (x86_64 assembly for dav1d, SVT-AV1 and libaom) and meson + ninja (dav1d), shared with scripts/build-ffmpeg.sh.
ensure_host_tools() { [[ -x "$WORK/host/bin/nasm" ]] || build_host_tools; }

arch_env() { # arch -> PREFIX, ARCH_FLAGS, HOST_TRIPLE for this slice
    ARCH="$1"
    PREFIX="$WORK/$ARCH/prefix"
    mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include"
    ARCH_FLAGS="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $SDK"
    [[ "$ARCH" == arm64 ]] && HOST_TRIPLE="aarch64-apple-darwin" || HOST_TRIPLE="x86_64-apple-darwin"
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH=""
}

# Runs a command with its output in a log; shows the tail of the log if it fails.
run() { # tag cmd...
    local tag="$1"; shift
    if ! "$@" >"$WORK/logs/$tag.log" 2>&1; then
        tail -40 "$WORK/logs/$tag.log" >&2
        die "step failed: $tag (log: $WORK/logs/$tag.log)"
    fi
}
run_in() { # dir tag cmd...
    local dir="$1" tag="$2"; shift 2
    run "$tag" bash -c 'cd "$1" && shift && "$@"' _ "$dir" "$@"
}

# ---------------------------------------------------------------------------------------------------------------
# The licence allow-list
# ---------------------------------------------------------------------------------------------------------------
licence_marker() { # SPDX -> a phrase every genuine text of that licence contains
    case "$1" in
        MIT) echo "Permission is hereby granted";;
        BSD-2-Clause) echo "Redistributions in binary form";;
        BSD-3-Clause) echo "Neither the name";;
        BSD-3-Clause-Clear) echo "Clear BSD";;
        Zlib) echo "Altered source versions must be plainly marked";;
        0BSD) echo "Permission to use, copy, modify, and/or distribute";;
        bzip2-1.0.6) echo "The origin of this software must not be misrepresented";;
        LGPL-2.1-only) echo "GNU LESSER GENERAL PUBLIC LICENSE";;
        *) die "no licence marker for $1";;
    esac
}

# Fails unless the component's licence is on the allow-list, its licence files exist and say what the table says,
# and (for anything that is not LGPL) they do not turn out to be GPL/AGPL texts. LGPL only as a dynamic library.
check_licence() { # id kind(static|dylib)
    local id="$1" kind="$2" spdx files f marker dir
    spdx="$(comp_field "$id" 2)"; files="$(comp_field "$id" 3)"; dir="$(srcdir "$id")"
    case " $ALLOWED_SPDX " in *" $spdx "*) ;; *) die "licence check: $id is $spdx, not on the allow-list ($ALLOWED_SPDX)";; esac
    case " $DYNAMIC_ONLY_SPDX " in *" $spdx "*) [[ "$kind" == dylib ]] || die "licence check: $id ($spdx) may only ship as a dynamic library";; esac
    marker="$(licence_marker "$spdx")"
    local found_marker=0
    for f in ${files//:/ }; do
        [[ -s "$dir/$f" ]] || die "licence check: $id has no $f"
        if grep -qiE "GNU AFFERO GENERAL PUBLIC LICENSE" "$dir/$f"; then die "licence check: $id/$f is an AGPL text"; fi
        if [[ "$spdx" != LGPL-* ]] && grep -qE "^ *GNU GENERAL PUBLIC LICENSE$" "$dir/$f"; then
            die "licence check: $id/$f is a GPL text"
        fi
        grep -qF "$marker" "$dir/$f" && found_marker=1
    done
    [[ "$found_marker" == 1 ]] || die "licence check: no licence file of $id contains '$marker' ($spdx)"
}

copy_licences() { # lib kind dest-dir  (check, then copy every component's licence files + COMPONENTS.txt)
    local lib="$1" kind="$2" dest="$3" id f
    mkdir -p "$dest"
    : > "$dest/COMPONENTS.txt"
    for id in $(components_of "$lib"); do
        check_licence "$id" "$kind"
        for f in $(comp_field "$id" 3 | tr ':' ' '); do
            cp "$(srcdir "$id")/$f" "$dest/$id-${f//\//-}"   # third_party/x86inc/LICENSE -> libaom-third_party-x86inc-LICENSE
        done
        lock_source "$id"
        printf '%s %s  %s  %s  sha256:%s\n' "$id" "$SRC_VERSION" "$(comp_field "$id" 2)" "$SRC_URL" "$SRC_SHA" >> "$dest/COMPONENTS.txt"
    done
}

# ---------------------------------------------------------------------------------------------------------------
# Build helpers
# ---------------------------------------------------------------------------------------------------------------
cmake_lib() { # tag srcdir extra-cmake-args...   (configure, build, install into $PREFIX for the current arch)
    local tag="$1" src="$2"; shift 2
    local bld="$WORK/$ARCH/build-$tag"
    run "$ARCH-$tag-configure" cmake -S "$src" -B "$bld" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" -DCMAKE_OSX_SYSROOT="$SDK" \
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local" -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF "$@"
    run "$ARCH-$tag-build" cmake --build "$bld" -j "$JOBS"
    run "$ARCH-$tag-install" cmake --install "$bld"
}

# Compiles files in parallel into $objdir; the object list is written to $objdir/objects.txt.
cc_one() { # exported: CC1 FLAGS1 SRCROOT1 OBJDIR1
    local f="$1" rel obj
    rel="${f#"$SRCROOT1"/}"
    obj="$OBJDIR1/$(echo "$rel" | tr '/' '_').o"
    # shellcheck disable=SC2086
    $CC1 $FLAGS1 -c "$f" -o "$obj"
}
export -f cc_one
compile_all() { # compiler flags srcroot objdir files...
    export CC1="$1" FLAGS1="$2" SRCROOT1="$3" OBJDIR1="$4"
    shift 4
    mkdir -p "$OBJDIR1"
    printf '%s\0' "$@" | xargs -0 -n1 -P "$JOBS" bash -c 'cc_one "$1"' _
    ls "$OBJDIR1"/*.o > "$OBJDIR1/objects.txt"
}

merge_static() { # output input.a...
    local out="$1"; shift
    mkdir -p "$(dirname "$out")"
    libtool -static -no_warning_for_no_symbols -o "$out" "$@"
}

# Assembles Vendor/<Name>.xcframework from per-arch libraries and zips it into dist/.
#   assemble Name kind libfile arm64-lib x86_64-lib headers-dir licences-dir
assemble() {
    local name="$1" kind="$2" libfile="$3" lib_arm="$4" lib_x86="$5" headers="$6" licences="$7"
    local xcf="$VENDOR/$name.xcframework" id="macos-arm64_x86_64" slice zip="$DIST/$name.xcframework.zip"
    rm -rf "$xcf"
    slice="$xcf/$id"
    mkdir -p "$slice"
    lipo -create "$lib_arm" "$lib_x86" -output "$slice/$libfile"
    [[ "$kind" == static ]] && { strip -S -x "$slice/$libfile" 2>/dev/null || true; }
    cp -R "$headers" "$slice/Headers"
    cat > "$xcf/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>$libfile</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>$id</string>
			<key>LibraryPath</key>
			<string>$libfile</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF
    cp -R "$licences" "$xcf/Licenses"
    mkdir -p "$DIST"
    rm -f "$zip"
    (cd "$VENDOR" && ditto -c -k --keepParent "$name.xcframework" "$zip")
    log "$name: $(lipo -archs "$slice/$libfile"), $(du -h "$slice/$libfile" | cut -f1) library, $(du -h "$zip" | cut -f1) zip, sha256 $(shasum -a 256 "$zip" | cut -d' ' -f1)"
}

# ---------------------------------------------------------------------------------------------------------------
# Libraries
# ---------------------------------------------------------------------------------------------------------------
build_webp() {
    local stage="$WORK/stage/webp"
    copy_licences webp static "$stage/Licenses"
    for arch in "${ARCHS[@]}"; do
        arch_env "$arch"
        log "libwebp $(ver libwebp) ($arch)"
        cmake_lib webp "$(srcdir libwebp)" \
            -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
            -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF \
            -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_LIBWEBPMUX=ON
        merge_static "$stage/$arch/libWebP.a" "$PREFIX/lib/libwebp.a" "$PREFIX/lib/libwebpdemux.a" \
            "$PREFIX/lib/libwebpmux.a" "$PREFIX/lib/libsharpyuv.a"
    done
    mkdir -p "$stage/Headers"
    cp -R "$WORK/arm64/prefix/include/webp" "$stage/Headers/webp"
    cat > "$stage/Headers/module.modulemap" <<'EOF'
module WebP {
    header "webp/types.h"
    header "webp/decode.h"
    header "webp/encode.h"
    header "webp/mux_types.h"
    header "webp/demux.h"
    header "webp/mux.h"
    export *
}
EOF
    assemble WebP static libWebP.a "$stage/arm64/libWebP.a" "$stage/x86_64/libWebP.a" "$stage/Headers" "$stage/Licenses"
}

build_avif() {
    local stage="$WORK/stage/avif"
    copy_licences avif static "$stage/Licenses"
    ensure_host_tools
    for arch in "${ARCHS[@]}"; do
        arch_env "$arch"
        log "dav1d $(ver dav1d) ($arch)"
        local cross="$WORK/$arch/meson.ini" kind=--native-file
        local cflags="'-arch','$arch','-mmacosx-version-min=$DEPLOYMENT_TARGET','-isysroot','$SDK'"
        local cpu=aarch64; [[ "$arch" == x86_64 ]] && cpu=x86_64
        {
            echo "[binaries]"; echo "c = 'clang'"; echo "ar = 'ar'"; echo "strip = 'strip'"
            echo "[built-in options]"; echo "c_args = [$cflags]"; echo "c_link_args = [$cflags]"
            if [[ "$(uname -m)" != "$arch" && "$arch" == x86_64 ]]; then
                kind=--cross-file
                echo "[host_machine]"; echo "system = 'darwin'"; echo "cpu_family = '$cpu'"; echo "cpu = '$cpu'"; echo "endian = 'little'"
            fi
        } > "$cross"
        run "$arch-dav1d-configure" meson setup "$WORK/$arch/build-dav1d" "$(srcdir dav1d)" "$kind" "$cross" \
            --buildtype=release --default-library=static --prefix="$PREFIX" --libdir=lib \
            -Denable_tools=false -Denable_tests=false -Denable_examples=false
        run "$arch-dav1d-build" meson install -C "$WORK/$arch/build-dav1d"

        log "SVT-AV1 $(ver svtav1) ($arch)"
        cmake_lib svtav1 "$(srcdir svtav1)" -DBUILD_APPS=OFF -DBUILD_DEC=OFF -DSVT_AV1_LTO=OFF

        # libaom's encoder only (dav1d decodes): no libyuv, WebM, tools or tests, so only its fastfeat, vector and
        # x86inc third-party code is compiled in. nasm assembles the x86_64 parts. AOM_TARGET_CPU is named because CMake
        # resets CMAKE_SYSTEM_PROCESSOR to the host's when it is not cross-compiling (NEON code in an x86_64 slice).
        log "libaom $(ver libaom) ($arch)"
        cmake_lib aom "$(srcdir libaom)" -DAOM_TARGET_CPU="$arch" -DCONFIG_AV1_DECODER=0 -DCONFIG_LIBYUV=0 -DCONFIG_WEBM_IO=0 -DCONFIG_PIC=1 \
            -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTDATA=0 -DENABLE_TESTS=0 -DENABLE_TOOLS=0 -DENABLE_NASM=1

        log "libavif $(ver libavif) ($arch)"
        cmake_lib avif "$(srcdir libavif)" \
            -DAVIF_CODEC_AOM=SYSTEM -DAVIF_CODEC_AOM_ENCODE=ON -DAVIF_CODEC_AOM_DECODE=OFF \
            -DAVIF_CODEC_RAV1E=OFF -DAVIF_CODEC_LIBGAV1=OFF -DAVIF_CODEC_AVM=OFF \
            -DAVIF_CODEC_DAV1D=SYSTEM -DAVIF_CODEC_SVT=SYSTEM -DAVIF_LIBYUV=OFF -DAVIF_LIBSHARPYUV=OFF \
            -DAVIF_JPEG=OFF -DAVIF_ZLIBPNG=OFF -DAVIF_BUILD_APPS=OFF -DAVIF_BUILD_TESTS=OFF \
            -DAVIF_BUILD_EXAMPLES=OFF -DAVIF_ENABLE_WERROR=OFF
        merge_static "$stage/$arch/libAVIF.a" "$PREFIX/lib/libavif.a" "$PREFIX/lib/libdav1d.a" "$PREFIX/lib/libSvtAv1Enc.a" \
            "$PREFIX/lib/libaom.a"
    done
    mkdir -p "$stage/Headers"
    cp -R "$WORK/arm64/prefix/include/avif" "$stage/Headers/avif"
    cat > "$stage/Headers/module.modulemap" <<'EOF'
module AVIF {
    header "avif/avif.h"
    export *
}
EOF
    assemble AVIF static libAVIF.a "$stage/arm64/libAVIF.a" "$stage/x86_64/libAVIF.a" "$stage/Headers" "$stage/Licenses"
}

build_archive() {
    local stage="$WORK/stage/archive"
    copy_licences archive static "$stage/Licenses"
    for arch in "${ARCHS[@]}"; do
        arch_env "$arch"
        log "liblzma $(ver xz), zstd $(ver zstd), lz4 $(ver lz4) ($arch)"
        cmake_lib xz "$(srcdir xz)" -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF \
            -DXZ_TOOL_SCRIPTS=OFF -DXZ_TOOL_SYMLINKS=OFF -DXZ_NLS=OFF -DXZ_DOXYGEN=OFF
        cmake_lib zstd "$(srcdir zstd)/build/cmake" -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_SHARED=OFF \
            -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_TESTS=OFF -DZSTD_LEGACY_SUPPORT=OFF
        cmake_lib lz4 "$(srcdir lz4)/build/cmake" -DLZ4_BUILD_CLI=OFF -DLZ4_BUILD_LEGACY_LZ4C=OFF \
            -DBUILD_STATIC_LIBS=ON
        log "libarchive $(ver libarchive) ($arch)"
        # zlib, bzip2 and iconv come from the SDK (libz, libbz2, libiconv); everything else is switched off so the
        # library never picks up a Homebrew OpenSSL, libxml2, expat or PCRE.
        local bld="$WORK/$arch/build-libarchive"
        run "$arch-libarchive-configure" cmake -S "$(srcdir libarchive)" -B "$bld" -G "Unix Makefiles" \
            -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_SYSTEM_PROCESSOR="$arch" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" -DCMAKE_OSX_SYSROOT="$SDK" \
            -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local" -DCMAKE_PREFIX_PATH="$PREFIX" \
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
            -DENABLE_TEST=OFF -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF \
            -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF -DENABLE_LIBB2=OFF \
            -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF -DENABLE_PCREPOSIX=OFF -DENABLE_PCRE2POSIX=OFF \
            -DENABLE_LZO=OFF -DENABLE_LIBGCC=OFF -DENABLE_CNG=OFF \
            -DENABLE_ZLIB=ON -DENABLE_BZip2=ON -DENABLE_LZMA=ON -DENABLE_ZSTD=ON -DENABLE_LZ4=ON -DENABLE_ICONV=ON
        run "$arch-libarchive-build" cmake --build "$bld" --target archive_static -j "$JOBS"
        merge_static "$stage/$arch/libArchive.a" "$bld/libarchive/libarchive.a" "$PREFIX/lib/liblzma.a" \
            "$PREFIX/lib/libzstd.a" "$PREFIX/lib/liblz4.a"
    done
    mkdir -p "$stage/Headers"
    cp "$(srcdir libarchive)/libarchive/archive.h" "$(srcdir libarchive)/libarchive/archive_entry.h" "$stage/Headers/"
    cat > "$stage/Headers/module.modulemap" <<'EOF'
module Archive {
    header "archive.h"
    header "archive_entry.h"
    link "z"
    link "bz2"
    link "iconv"
    export *
}
EOF
    assemble Archive static libArchive.a "$stage/arm64/libArchive.a" "$stage/x86_64/libArchive.a" "$stage/Headers" "$stage/Licenses"
}

build_xls() {
    local stage="$WORK/stage/xls"
    copy_licences xls static "$stage/Licenses"
    for arch in "${ARCHS[@]}"; do
        arch_env "$arch"
        log "libxls $(ver libxls) ($arch)"
        local bld="$WORK/$arch/build-libxls"
        mkdir -p "$bld"
        run_in "$bld" "$arch-libxls-configure" "$(srcdir libxls)/configure" --prefix="$PREFIX" \
            --host="$HOST_TRIPLE" --disable-shared --enable-static --disable-dependency-tracking \
            CC=clang CFLAGS="$ARCH_FLAGS -O2" LDFLAGS="$ARCH_FLAGS"
        run_in "$bld" "$arch-libxls-build" make -j "$JOBS" install-exec install-data
        merge_static "$stage/$arch/libXLS.a" "$PREFIX/lib/libxlsreader.a"
    done
    mkdir -p "$stage/Headers"
    cp -R "$WORK/arm64/prefix/include/libxls" "$stage/Headers/libxls"
    cp "$WORK/arm64/prefix/include/xls.h" "$stage/Headers/xls.h"
    cat > "$stage/Headers/module.modulemap" <<'EOF'
module XLS {
    header "xls.h"
    link "iconv"
    export *
}
EOF
    assemble XLS static libXLS.a "$stage/arm64/libXLS.a" "$stage/x86_64/libXLS.a" "$stage/Headers" "$stage/Licenses"
}

build_woff2() {
    local stage="$WORK/stage/woff2"
    copy_licences woff2 static "$stage/Licenses"
    local w="$(srcdir woff2)"
    for arch in "${ARCHS[@]}"; do
        arch_env "$arch"
        log "Brotli $(ver brotli) + woff2 $(ver woff2) ($arch)"
        cmake_lib brotli "$(srcdir brotli)" -DBROTLI_DISABLE_TESTS=ON -DBROTLI_BUILD_TOOLS=OFF
        compile_all "clang++" "$ARCH_FLAGS -std=c++17 -O2 -fPIC -DOS_MACOSX -D__STDC_FORMAT_MACROS -I$w/src -I$w/include -I$PREFIX/include -I$VENDOR_SCRIPTS/shims" \
            "$w" "$WORK/$arch/obj-woff2" \
            "$w"/src/{font,glyph,normalize,table_tags,transform,variable_length,woff2_common,woff2_dec,woff2_enc,woff2_out}.cc \
            "$VENDOR_SCRIPTS/shims/woff2_c.cc"
        # shellcheck disable=SC2046
        merge_static "$stage/$arch/libWOFF2.a" $(cat "$WORK/$arch/obj-woff2/objects.txt") \
            "$PREFIX/lib/libbrotlienc.a" "$PREFIX/lib/libbrotlidec.a" "$PREFIX/lib/libbrotlicommon.a"
    done
    mkdir -p "$stage/Headers"
    cp "$VENDOR_SCRIPTS/shims/woff2_c.h" "$stage/Headers/"
    cat > "$stage/Headers/module.modulemap" <<'EOF'
module WOFF2 {
    header "woff2_c.h"
    link "c++"
    export *
}
EOF
    assemble WOFF2 static libWOFF2.a "$stage/arm64/libWOFF2.a" "$stage/x86_64/libWOFF2.a" "$stage/Headers" "$stage/Licenses"
}

build_unalz() {
    local stage="$WORK/stage/unalz"
    copy_licences unalz static "$stage/Licenses"
    # The readme is a licence notice followed by a long Korean changelog: ship only the (English) zlib licence part.
    LC_ALL=C tr -d '\r' < "$stage/Licenses/unalz-readme.txt" | LC_ALL=C sed -n '1,/This notice may not be removed or altered/p' > "$stage/Licenses/unalz-LICENSE.txt"
    rm "$stage/Licenses/unalz-readme.txt"
    grep -qF "Altered source versions" "$stage/Licenses/unalz-LICENSE.txt" || die "licence check: unalz licence text not found"
    local u="$(srcdir unalz)"
    # unalz carries a modified copy of bzip2 1.0.5 whose symbols clash with the system libbz2 that libarchive links, so
    # every BZ2_* name is renamed at compile time. zlib comes from the SDK.
    grep -ohE 'BZ2_[A-Za-z0-9_]+' "$u"/*.c "$u"/*.cpp "$u"/*.h "$u"/bzip2/* | sort -u \
        | awk '{print "#define " $1 " unalz_" $1}' > "$WORK/unalz-renames.h"
    for arch in "${ARCHS[@]}"; do
        arch_env "$arch"
        log "unalz $(ver unalz) ($arch)"
        local common="$ARCH_FLAGS -O2 -fPIC -w -D_UNALZ_ICONV -D_UNALZ_UTF8 -D_LARGEFILE64_SOURCE -D_FILE_OFFSET_BITS=64 -include $WORK/unalz-renames.h -I$u -I$VENDOR_SCRIPTS/shims"
        compile_all "clang" "$common" "$u" "$WORK/$arch/obj-unalz-c" \
            "$u"/UnAlzBz2decompress.c "$u"/UnAlzbzlib.c "$u"/bzip2/{blocksort,compress,crctable,huffman,randtable}.c
        compile_all "clang++" "$common -std=c++14" "$u" "$WORK/$arch/obj-unalz-cc" \
            "$u"/UnAlz.cpp "$u"/UnAlzUtils.cpp "$u"/UnAlzBzip2.cpp "$VENDOR_SCRIPTS/shims/unalz_c.cc"
        # shellcheck disable=SC2046
        merge_static "$stage/$arch/libUnALZ.a" $(cat "$WORK/$arch/obj-unalz-c/objects.txt" "$WORK/$arch/obj-unalz-cc/objects.txt")
    done
    mkdir -p "$stage/Headers"
    cp "$VENDOR_SCRIPTS/shims/unalz_c.h" "$stage/Headers/"
    cat > "$stage/Headers/module.modulemap" <<'EOF'
module UnALZ {
    header "unalz_c.h"
    link "c++"
    link "z"
    link "iconv"
    export *
}
EOF
    assemble UnALZ static libUnALZ.a "$stage/arm64/libUnALZ.a" "$stage/x86_64/libUnALZ.a" "$stage/Headers" "$stage/Licenses"
}

build_libraw() {
    local stage="$WORK/stage/libraw"
    copy_licences libraw dylib "$stage/Licenses"
    local r="$(srcdir libraw)"
    # X3F decoding is Roland Karlsson's BSD-3-Clause X3F tools, compiled in with USE_X3FTOOLS; keep its notice.
    awk '/Library for accessing X3F Files/ {p=1} p {print} p && /^\*\/|\*\/$/ {exit}' "$r/src/x3f/x3f_parse_process.cpp" \
        > "$stage/Licenses/LibRaw-x3f-tools-LICENSE.txt"
    grep -qF "Neither the name" "$stage/Licenses/LibRaw-x3f-tools-LICENSE.txt" \
        || die "licence check: LibRaw's X3F tools no longer carry the BSD-3-Clause text we verified"
    printf 'x3f-tools (inside LibRaw %s)  BSD-3-Clause  Roland Karlsson 2010, src/x3f/\n' "$(ver libraw)" >> "$stage/Licenses/COMPONENTS.txt"
    # LibRaw has no CMake in the source release and its configure needs autoreconf; the library is a flat list of
    # C++ files, so compile them directly (the list is Makefile.am's `lib_libraw_a_SOURCES`). No OpenMP, no
    # lcms, no libjpeg (lossy DNG goes through Core Image), zlib from the SDK for deflate DNG.
    for arch in "${ARCHS[@]}"; do
        arch_env "$arch"
        log "LibRaw $(ver libraw) ($arch)"
        local files=()
        while IFS= read -r f; do files+=("$r/$f"); done < <(awk '/^lib_libraw_a_SOURCES/ {p=1} p {print} p && /^$/ {exit}' "$r/Makefile.am" | grep -oE 'src/[^ \\]+\.cpp')
        compile_all "clang++" "$ARCH_FLAGS -std=c++14 -O2 -fPIC -w -pthread -DUSE_X3FTOOLS -DUSE_ZLIB -DLIBRAW_BUILDLIB -I$r" \
            "$r" "$WORK/$arch/obj-libraw" "${files[@]}"
        mkdir -p "$stage/$arch"
        # shellcheck disable=SC2046
        run "$arch-libraw-link" clang++ -dynamiclib $ARCH_FLAGS -pthread -install_name @rpath/libraw_r.dylib \
            -o "$stage/$arch/libraw_r.dylib" $(cat "$WORK/$arch/obj-libraw/objects.txt") -lz
    done
    mkdir -p "$stage/Headers"
    cp -R "$r/libraw" "$stage/Headers/libraw"
    cat > "$stage/Headers/module.modulemap" <<'EOF'
module LibRaw {
    header "libraw/libraw.h"
    link "raw_r"
    export *
}
EOF
    assemble LibRaw dylib libraw_r.dylib "$stage/arm64/libraw_r.dylib" "$stage/x86_64/libraw_r.dylib" "$stage/Headers" "$stage/Licenses"
    # LGPL: the corresponding source is published next to the binary.
    mkdir -p "$DIST"
    lock_source libraw
    cp "$SRC_CACHE/$SRC_FILE" "$DIST/LibRaw-$SRC_VERSION-source.tar.gz"
}

# ---------------------------------------------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------------------------------------------
resolve_libs() { # args -> lib names
    if [[ $# -eq 0 || "$1" == all ]]; then printf '%s\n' "${LIBS[@]}"; return; fi
    local l
    for l in "$@"; do
        case " ${LIBS[*]} " in *" $l "*) echo "$l";; *) die "unknown library '$l' (one of: ${LIBS[*]})";; esac
    done
}

cmd_build() {
    setup_env
    mkdir -p "$VENDOR" "$DIST"
    local lib start
    for lib in $(resolve_libs "$@"); do
        start=$SECONDS
        "build_$lib"
        log "$lib built in $((SECONDS - start)) s"
    done
}

cmd_licenses() {
    setup_env
    local lib id kind
    for lib in "${LIBS[@]}"; do
        kind="$(lib_kind "$lib")"
        for id in $(components_of "$lib"); do
            check_licence "$id" "$kind"
            log "licence ok: $id $(ver "$id") ($(comp_field "$id" 2), $kind)"
        done
    done
}

cmd_verify() {
    setup_env
    local libs lib name pkg="$WORK/smoke" targets="" products="" arch bin
    libs="$(resolve_libs "$@")"
    mkdir -p "$pkg/Sources"
    /usr/bin/python3 -I "$VENDOR_SCRIPTS/smoke/make-fixtures.py" "$WORK/fixtures"
    cp "$VENDOR_SCRIPTS/smoke/fixture.xls" "$WORK/fixtures/"
    local deps_decl=""
    for lib in $libs; do
        name="$(xcf_name "$lib")"
        [[ -d "$VENDOR/$name.xcframework" ]] || die "$VENDOR/$name.xcframework missing (run build or scripts/fetch-vendor.sh first)"
        check_xcframework "$name" "$(lib_kind "$lib")"
        cp -R "$VENDOR/$name.xcframework" "$pkg/$name.xcframework"
        mkdir -p "$pkg/Sources/smoke-$lib"
        cp "$VENDOR_SCRIPTS/smoke/$lib.swift" "$pkg/Sources/smoke-$lib/main.swift"
        deps_decl+="        .binaryTarget(name: \"$name\", path: \"$name.xcframework\"),
        .executableTarget(name: \"smoke-$lib\", dependencies: [\"$name\"], path: \"Sources/smoke-$lib\"),
"
    done
    cat > "$pkg/Package.swift" <<EOF
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "vendor-smoke",
    platforms: [.macOS(.v14)],
    targets: [
$deps_decl    ]
)
EOF
    for arch in "${ARCHS[@]}"; do
        for lib in $libs; do
            log "Smoke test $lib ($arch)"
            # The Command Line Tools ship the Swift back-deployment compatibility libraries for arm64 only.
            run "smoke-build-$lib-$arch" swift build --package-path "$pkg" -c release --product "smoke-$lib" \
                --triple "$arch-apple-macosx$DEPLOYMENT_TARGET" -Xswiftc -runtime-compatibility-version -Xswiftc none
            bin="$pkg/.build/$arch-apple-macosx/release/smoke-$lib"
            [[ "$(lipo -archs "$bin")" == "$arch" ]] || die "smoke binary for $lib is not $arch"
            smoke_run "$arch" "$bin" "$WORK/fixtures"
        done
    done
    log "All smoke tests passed on arm64 and x86_64: $(echo $libs)"
}

smoke_run() { # arch binary fixtures-dir
    arch "-$1" "$2" "$3" || die "smoke test $(basename "$2") failed on $1"
}

# Static checks on a built xcframework: both slices, the deployment target, licences present, no Homebrew paths.
check_xcframework() { # Name kind
    local name="$1" kind="$2" xcf="$VENDOR/$1.xcframework" lib minos
    lib="$(ls "$xcf"/macos-arm64_x86_64/lib* | head -1)"
    [[ "$(lipo -archs "$lib" | tr ' ' '\n' | sort | tr '\n' ' ')" == "arm64 x86_64 " ]] || die "$name is not universal: $(lipo -archs "$lib")"
    [[ -s "$xcf/Licenses/COMPONENTS.txt" ]] || die "$name has no Licenses/COMPONENTS.txt"
    [[ -n "$(ls "$xcf"/Licenses | grep -v COMPONENTS.txt)" ]] || die "$name has no licence texts"
    if [[ "$kind" == dylib ]]; then
        grep -q "/opt/homebrew\|/usr/local" <<< "$(otool -L "$lib" | tail -n +2)" && die "$name links a Homebrew library"
        for arch in "${ARCHS[@]}"; do
            minos="$(vtool -arch "$arch" -show-build "$lib" | awk '$1=="minos" {print $2}')"
            [[ "$minos" == "$DEPLOYMENT_TARGET" ]] || die "$name $arch minos is '$minos', want $DEPLOYMENT_TARGET"
        done
    else
        local tmp="$WORK/minos-$name"; mkdir -p "$tmp"
        for arch in "${ARCHS[@]}"; do
            lipo "$lib" -thin "$arch" -output "$tmp/$arch.a"
            ( cd "$tmp" && mkdir -p "$arch" && cd "$arch" && ar -x "../$arch.a" 2>/dev/null )
            minos="$(vtool -arch "$arch" -show-build "$(ls "$tmp/$arch"/*.o | head -1)" | awk '$1=="minos" {print $2}' | sort -u | tr '\n' ' ')"
            [[ "$minos" == "$DEPLOYMENT_TARGET " ]] || die "$name $arch objects have minos '$minos', want $DEPLOYMENT_TARGET"
        done
        rm -rf "$tmp"
    fi
}

NOTICES_BEGIN="<!-- BEGIN vendor-libraries (generated by scripts/build-vendor.sh notices write) -->"
NOTICES_END="<!-- END vendor-libraries -->"
NOTICES_FILE="$ROOT/THIRD_PARTY_NOTICES.md"

notices_section() { # needs the built or fetched Vendor/*.xcframework (their Licenses/ hold the texts)
    local lib name id f xcf
    echo "## Bundled libraries (\`Contents/Frameworks/\` and linked into the app)"
    echo
    echo "Built from the pinned, unmodified upstream source by \`scripts/build-vendor.sh\` (pins in \`Vendor.lock\`); each"
    echo "\`.xcframework\` carries its licence texts in \`Licenses/\`. The static libraries are linked into the app. LibRaw (LGPL)"
    echo "is a separate dynamic library, \`libraw_r.dylib\`, that a person can replace; its source tarball is published as"
    echo "\`LibRaw-<version>-source.tar.gz\` next to the binary on the GitHub release listed in \`Vendor.lock\`."
    echo
    echo "| Component | Version | Licence | In | Source | Source SHA-256 |"
    echo "|---|---|---|---|---|---|"
    for lib in "${LIBS[@]}"; do
        for id in $(components_of "$lib"); do
            lock_source "$id"
            echo "| $id | $SRC_VERSION | $(comp_field "$id" 2) | $(xcf_name "$lib") ($(lib_kind "$lib")) | $SRC_URL | \`$SRC_SHA\` |"
        done
    done
    echo "| x3f-tools (inside LibRaw) | as LibRaw | BSD-3-Clause | LibRaw (dynamic) | LibRaw \`src/x3f/\` | as LibRaw |"
    echo
    echo "Notes: unalz includes a modified copy of bzip2 1.0.5 (its symbols are renamed so it cannot clash with the system"
    echo "libbz2); its licence is the bzip2 licence. zstd is dual-licensed BSD-3-Clause / GPL-2.0 and we use it under"
    echo "BSD-3-Clause. LibRaw is dual-licensed LGPL-2.1 / CDDL-1.0 and we use it under LGPL-2.1. libarchive includes BLAKE2"
    echo "reference code covered by its COPYING. libavif is built without libyuv and libsharpyuv. libaom is built as an"
    echo "encoder only; of its third-party code it compiles in fastfeat (BSD-3-Clause), vector (MIT) and x86inc (ISC), whose"
    echo "licences are reproduced below. nasm, meson and ninja are build tools and are not shipped."
    for lib in "${LIBS[@]}"; do
        name="$(xcf_name "$lib")"; xcf="$VENDOR/$name.xcframework"
        [[ -d "$xcf/Licenses" ]] || die "$xcf missing: build or fetch it before generating the notices"
        echo
        echo "### $name licence texts"
        for f in "$xcf"/Licenses/*; do
            [[ "$(basename "$f")" == COMPONENTS.txt ]] && continue
            echo
            echo "<details><summary>$(basename "$f")</summary>"
            echo
            echo '```text'
            iconv -f UTF-8 -t UTF-8 -c "$f" | sed 's/[[:space:]]*$//'
            echo '```'
            echo
            echo "</details>"
        done
    done
}

cmd_notices() { # [write|check]: print the section, write it between its markers in THIRD_PARTY_NOTICES.md, or fail if stale
    setup_env
    local section="$WORK/notices-section.md"
    { printf '%s\n\n' "$NOTICES_BEGIN"; notices_section; printf '\n%s\n' "$NOTICES_END"; } > "$section"
    case "${1:-}" in
        "") cat "$section" ;;
        write)
            if grep -qF "$NOTICES_BEGIN" "$NOTICES_FILE" 2>/dev/null; then
                awk -v b="$NOTICES_BEGIN" -v e="$NOTICES_END" -v sec="$section" '
                    $0 == b { while ((getline line < sec) > 0) print line; skip = 1; next }
                    $0 == e { skip = 0; next }
                    !skip { print }' "$NOTICES_FILE" > "$WORK/notices.new"
            else
                { cat "$NOTICES_FILE" 2>/dev/null || printf '# Third-party notices\n'; printf '\n'; cat "$section"; } > "$WORK/notices.new"
            fi
            cp "$WORK/notices.new" "$NOTICES_FILE"
            log "Updated $NOTICES_FILE" ;;
        check)
            awk -v b="$NOTICES_BEGIN" -v e="$NOTICES_END" '$0 == b { p = 1 } p { print } $0 == e { p = 0 }' "$NOTICES_FILE" \
                | cmp -s - "$section" || die "$NOTICES_FILE is stale: run scripts/build-vendor.sh notices write" ;;
        *) die "usage: $0 notices [write|check]" ;;
    esac
}

cmd_release() {
    local tag="${1:-vendor-$(date +%Y%m%d)}" asset
    command -v gh >/dev/null || die "gh not found"
    local assets=("$DIST"/*.xcframework.zip)
    [[ -f "${assets[0]}" ]] || die "nothing in $DIST (run build first)"
    local all_assets=("${assets[@]}")
    local f
    for f in "$DIST"/*-source.tar.gz; do [[ -f "$f" ]] && all_assets+=("$f"); done
    make_work   # for lock_set; the release step needs the caller's PATH (gh), so not setup_env
    # Always a prerelease, so it never becomes the repository's "latest" release (the app's updater reads that).
    if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
        gh release upload "$tag" "${all_assets[@]}" --repo "$REPO" --clobber
    else
        gh release create "$tag" "${all_assets[@]}" --repo "$REPO" --prerelease --latest=false \
            --title "Vendor libraries $tag" --notes \
"Static universal (arm64 + x86_64) xcframeworks for macOS $DEPLOYMENT_TARGET+ built by \`scripts/build-vendor.sh\` from pinned upstream source, plus LibRaw as a dynamic library (LGPL-2.1) with its source tarball. Licences: THIRD_PARTY_NOTICES.md and Licenses/ inside each zip. Consumed through Vendor.lock and \`scripts/fetch-vendor.sh\`; not an app release."
    fi
    lock_set release - "$tag"
    for asset in "${assets[@]}"; do lock_set asset "$(basename "$asset")" "$(sha256_of "$asset")"; done
    log "Published $tag; pins written to Vendor.lock"
}
case "${1:-}" in
    build) shift; cmd_build "$@" ;;
    verify) shift; cmd_verify "$@" ;;
    licenses) cmd_licenses ;;
    notices) shift; cmd_notices "$@" ;;
    release) shift; cmd_release "$@" ;;
    *) die "usage: $0 build|verify|licenses|notices|release [args]" ;;
esac
