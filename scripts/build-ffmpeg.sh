#!/bin/bash
# Builds the LGPL-only FFmpeg 7.1 `ffmpeg` and `ffprobe` executables, universal (arm64 + x86_64), for macOS 14+.
#
#   scripts/build-ffmpeg.sh build    download pinned sources (SHA-256 from Tools.lock), build every library and FFmpeg
#                                    statically per architecture, lipo into Vendor/Tools/{ffmpeg,ffprobe}
#   scripts/build-ffmpeg.sh fetch    download the published binaries instead (scripts/tools.sh fetch)
#
# Verify with `scripts/tools.sh check` (licence, linkage, slices) and `scripts/tools.sh smoke`.
#
# Recipe (docs/ARCHITECTURE.md WP0c, docs/specs/formats.md §2-3):
#   - LGPL-3.0-or-later as a whole: --enable-version3 --disable-gpl --disable-nonfree, nothing else that is GPL
#   - video: VideoToolbox (H.264/HEVC/ProRes encode+decode), libvpx (VP8/VP9), SVT-AV1 (AV1 encode), dav1d (AV1
#     decode), libtheora; audio: AudioToolbox (AAC/ALAC/...), libopus, libvorbis, LAME, opencore-amr (decode),
#     vo-amrwbenc (AMR-WB encode); images/subtitles/filters: libwebp, libass (+ HarfBuzz, FreeType, FriBidi, CoreText
#     fonts), soxr, zimg; system zlib, bzip2, iconv. No x264/x265/xvid/fdk-aac/libxavs/frei0r/rubberband/openssl.
#   - static; the only dynamic dependencies are macOS system libraries and frameworks (checked with otool -L)
#   - no network protocols, no ffplay, no capture devices (only the lavfi source, for generated test input and silence)
# Needs: Command Line Tools (clang, make, lipo), cmake >= 3.16, pkg-config, autoconf/automake/libtool (Homebrew;
# build tools only, nothing from /opt/homebrew is linked or searched), curl, python3, network for pip (meson, ninja).
set -euo pipefail
source "$(dirname "$0")/tools-common.sh"

[[ "${1:-}" == fetch ]] && exec "$ROOT/scripts/tools.sh" fetch

FFMPEG_LIBS=(libvpx svtav1 dav1d opus libogg libvorbis libtheora lame opencore voamrwbenc libwebp soxr zimg
             freetype fribidi harfbuzz libass)

build_arch() { # arch
    local arch="$1" sdk jobs host_triple
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
    jobs="$(sysctl -n hw.ncpu)"
    local P="$WORK/$arch/prefix" S="$WORK/$arch/src" B="$WORK/$arch/build"
    mkdir -p "$P" "$S" "$B"

    # config.guess says arm64 on this machine; name both triples explicitly.
    case "$arch" in
        arm64)  host_triple="aarch64-apple-darwin" ;;
        x86_64) host_triple="x86_64-apple-darwin" ;;
    esac

    local cflags="-arch $arch -O2 -isysroot $sdk -mmacosx-version-min=$DEPLOYMENT_TARGET -I$P/include"
    local ldflags="-arch $arch -isysroot $sdk -mmacosx-version-min=$DEPLOYMENT_TARGET -L$P/lib"
    export PATH="$WORK/host/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"   # Homebrew last: build tools only
    export CC="clang -arch $arch" CXX="clang++ -arch $arch" OBJC="clang -arch $arch"
    export CFLAGS="$cflags" CXXFLAGS="$cflags" OBJCFLAGS="$cflags" LDFLAGS="$ldflags" CPPFLAGS="-I$P/include"
    export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    export PKG_CONFIG_LIBDIR="$P/lib/pkgconfig" PKG_CONFIG_PATH="" PKG_CONFIG_SYSROOT_DIR=""
    export LIBTOOLIZE=glibtoolize

    local cmake_common=(
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_INSTALL_LIBDIR=lib
        -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" -DCMAKE_OSX_SYSROOT="$sdk"
        -DCMAKE_SYSTEM_PROCESSOR="$arch" -DCMAKE_PREFIX_PATH="$P"
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local"
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DCMAKE_ASM_NASM_COMPILER="$WORK/host/bin/nasm"
    )
    cmake_build() { # name srcdir [extra cmake args...]
        local name="$1" src="$2"; shift 2
        cmake -S "$src" -B "$B/$name" "${cmake_common[@]}" "$@" >/dev/null
        cmake --build "$B/$name" -j "$jobs" >/dev/null
        cmake --install "$B/$name" >/dev/null
    }
    local make_args=()   # extra `make` arguments for the next autotools_build only
    autotools_build() { # srcdir [extra configure args...]; builds in tree
        local src="$1"; shift
        # Old config.sub/config.guess (LAME, opencore-amr) do not know arm64 macOS.
        local lib f; lib="$(automake --print-libdir)"
        for f in config.sub config.guess; do [[ -f "$src/$f" ]] && cp "$lib/$f" "$src/$f"; done
        (cd "$src" && ./configure --prefix="$P" --host="$host_triple" --disable-shared --enable-static \
            --disable-dependency-tracking "$@" >/dev/null && make -j "$jobs" ${make_args[@]+"${make_args[@]}"} >/dev/null &&
            make install >/dev/null)
    }
    meson_build() { # name srcdir [meson args...]
        local name="$1" src="$2"; shift 2
        meson setup "$B/$name" "$src" --cross-file "$WORK/$arch/meson.ini" --prefix "$P" --libdir lib \
            --default-library static --buildtype release "$@" >/dev/null
        meson compile -C "$B/$name" >/dev/null
        meson install -C "$B/$name" >/dev/null
    }
    unpack() { unpack_source "$1" "$S/$1"; }   # sets SRC_DIR

    cat > "$WORK/$arch/meson.ini" <<EOM
[binaries]
c = ['clang', '-arch', '$arch']
cpp = ['clang++', '-arch', '$arch']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'darwin'
cpu_family = '$arch'
cpu = '$arch'
endian = 'little'
[properties]
needs_exe_wrapper = false
[built-in options]
c_args = ['-isysroot', '$sdk', '-mmacosx-version-min=$DEPLOYMENT_TARGET', '-O2']
cpp_args = ['-isysroot', '$sdk', '-mmacosx-version-min=$DEPLOYMENT_TARGET', '-O2']
c_link_args = ['-isysroot', '$sdk', '-mmacosx-version-min=$DEPLOYMENT_TARGET']
cpp_link_args = ['-isysroot', '$sdk', '-mmacosx-version-min=$DEPLOYMENT_TARGET']
EOM

    log "[$arch] libvpx"; unpack libvpx
    (mkdir -p "$B/libvpx" && cd "$B/libvpx" && "$SRC_DIR/configure" --prefix="$P" --target="$arch-darwin20-gcc" \
        --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth --enable-pic --enable-runtime-cpu-detect \
        --enable-multithread --disable-shared --enable-static --disable-examples --disable-tools --disable-docs \
        --disable-unit-tests --disable-webm-io --extra-cflags="-mmacosx-version-min=$DEPLOYMENT_TARGET" >/dev/null &&
        make -j "$jobs" >/dev/null && make install >/dev/null)

    log "[$arch] SVT-AV1"; unpack svtav1
    cmake_build svtav1 "$SRC_DIR" -DBUILD_APPS=OFF -DBUILD_TESTING=OFF -DENABLE_AVX512=OFF

    log "[$arch] dav1d"; unpack dav1d
    meson_build dav1d "$SRC_DIR" -Denable_tools=false -Denable_tests=false -Denable_examples=false

    log "[$arch] opus"; unpack opus
    autotools_build "$SRC_DIR" --disable-doc --disable-extra-programs

    log "[$arch] libogg"; unpack libogg
    autotools_build "$SRC_DIR"
    log "[$arch] libvorbis"; unpack libvorbis
    # libvorbis' configure replaces CFLAGS on Darwin with one containing -force_cpusubtype_ALL, which ld rejects.
    make_args=(CFLAGS="$cflags -fno-common -ffast-math -fsigned-char")
    autotools_build "$SRC_DIR" --disable-oggtest --disable-examples --disable-docs
    make_args=()
    log "[$arch] libtheora"; unpack libtheora
    autotools_build "$SRC_DIR" --disable-oggtest --disable-vorbistest --disable-sdltest --disable-examples \
        --disable-doc --disable-spec --disable-asm

    log "[$arch] LAME"; unpack lame
    autotools_build "$SRC_DIR" --disable-frontend --disable-gtktest --disable-decoder
    log "[$arch] opencore-amr"; unpack opencore
    autotools_build "$SRC_DIR"
    log "[$arch] vo-amrwbenc"; unpack voamrwbenc
    autotools_build "$SRC_DIR"

    log "[$arch] libwebp"; unpack libwebp
    cmake_build libwebp "$SRC_DIR" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
        -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
    log "[$arch] soxr"; unpack soxr
    cmake_build soxr "$SRC_DIR" -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_OPENMP=OFF -DWITH_LSR_BINDINGS=OFF
    log "[$arch] zimg"; unpack zimg
    (cd "$SRC_DIR" && autoreconf -fi >/dev/null 2>&1)
    autotools_build "$SRC_DIR" --disable-testapp --disable-example --disable-unit-test

    log "[$arch] FreeType"; unpack freetype
    autotools_build "$SRC_DIR" --with-harfbuzz=no --with-png=no --with-brotli=no --with-bzip2=no --with-zlib=yes
    log "[$arch] FriBidi"; unpack fribidi
    meson_build fribidi "$SRC_DIR" -Ddocs=false -Dbin=false -Dtests=false
    log "[$arch] HarfBuzz"; unpack harfbuzz
    meson_build harfbuzz "$SRC_DIR" -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
        -Dicu=disabled -Dcoretext=disabled -Dtests=disabled -Ddocs=disabled -Dbenchmark=disabled -Dutilities=disabled
    log "[$arch] libass"; unpack libass
    autotools_build "$SRC_DIR" --disable-fontconfig --enable-coretext --disable-require-system-font-provider

    log "[$arch] FFmpeg"; unpack ffmpeg
    local cross=()
    [[ "$arch" != "$(uname -m)" ]] && cross=(--enable-cross-compile)
    (mkdir -p "$B/ffmpeg" && cd "$B/ffmpeg" && "$SRC_DIR/configure" --prefix="$WORK/$arch/ffmpeg-install" \
        --cc="clang -arch $arch" --cxx="clang++ -arch $arch" --arch="$arch" --target-os=darwin ${cross[@]+"${cross[@]}"} \
        --extra-cflags="$cflags" --extra-ldflags="$ldflags" --pkg-config-flags=--static \
        --enable-version3 --disable-gpl --disable-nonfree --disable-autodetect \
        --enable-static --disable-shared --disable-debug --disable-doc --disable-ffplay \
        --disable-network --disable-indevs --enable-indev=lavfi --disable-outdevs \
        --enable-zlib --enable-bzlib --enable-iconv --enable-audiotoolbox --enable-videotoolbox \
        --enable-libvpx --enable-libsvtav1 --enable-libdav1d \
        --enable-libopus --enable-libvorbis --enable-libtheora --enable-libmp3lame \
        --enable-libopencore-amrnb --enable-libopencore-amrwb --enable-libvo-amrwbenc \
        --enable-libwebp --enable-libsoxr --enable-libzimg \
        --enable-libass --enable-libfreetype --enable-libharfbuzz --enable-libfribidi >/dev/null &&
        make -j "$jobs" >/dev/null && make install >/dev/null)
}

cmd_build() {
    command -v cmake >/dev/null || die "cmake not found (brew install cmake)"
    command -v pkg-config >/dev/null || die "pkg-config not found (brew install pkg-config)"
    command -v autoreconf >/dev/null || die "autoconf/automake/libtool not found (brew install autoconf automake libtool)"
    make_work
    log "Fetching and checking sources"
    local id
    for id in nasm ffmpeg "${FFMPEG_LIBS[@]}"; do fetch_source "$id"; done

    local start=$SECONDS
    build_host_tools
    local pids=() arch
    for arch in "${ARCHS[@]}"; do
        mkdir -p "$WORK/$arch"
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

    local tool
    for tool in ffmpeg ffprobe; do
        local slices=()
        for arch in "${ARCHS[@]}"; do slices+=("$WORK/$arch/ffmpeg-install/bin/$tool"); done
        lipo_binaries "$TOOLS_DIR/$tool" "${slices[@]}"
    done
    log "Built in $((SECONDS - start)) s"
    for tool in ffmpeg ffprobe; do
        log "$tool: $(lipo -archs "$TOOLS_DIR/$tool"), $(du -h "$TOOLS_DIR/$tool" | cut -f1)"
    done
}

case "${1:-}" in
    build) cmd_build ;;
    *) die "usage: $0 build|fetch" ;;
esac
