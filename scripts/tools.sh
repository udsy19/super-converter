#!/bin/bash
# Checks, tests, packages, publishes and fetches the bundled executables (ffmpeg, ffprobe, 7zz) in Vendor/Tools.
#
#   scripts/tools.sh check      licence (no GPL / nonfree FFmpeg), universal slices, linkage (system libraries only),
#                               deployment target
#   scripts/tools.sh smoke [ffmpeg|7zz]   real conversions and archive round trips on every slice (x86_64 runs under Rosetta)
#   scripts/tools.sh package    dist/tools-macos-universal.zip (binaries + Licenses/) and dist/tools-sources.tar.gz
#                               (every upstream tarball, the build scripts and Tools.lock: the LGPL source)
#   scripts/tools.sh release    publish both as assets of a GitHub PRERELEASE `tools-<date>` on udsy19/super-converter
#                               and pin its checksums in Tools.lock
#   scripts/tools.sh fetch      download the pinned release asset (gh, authenticated), check its SHA-256 against
#                               Tools.lock, unpack into Vendor/Tools and run `check`
#   scripts/tools.sh licenses <dir>   copy every component's licence files out of the pinned sources
#   scripts/tools.sh notices [write|check]   print the generated "Bundled executables" section of
#                               THIRD_PARTY_NOTICES.md, write it between its markers, or fail if the file is stale
#
# Needs: Command Line Tools, curl, shasum, ditto, python3; gh for release/fetch.
set -euo pipefail
source "$(dirname "$0")/tools-common.sh"

BIN_ASSET="tools-macos-universal.zip"
SRC_ASSET="tools-sources.tar.gz"

# id | name | SPDX licence | homepage | licence files inside the tarball (relative to its top-level directory)
COMPONENTS=(
"ffmpeg|FFmpeg|LGPL-3.0-or-later (built without --enable-gpl and --enable-nonfree)|https://ffmpeg.org|COPYING.LGPLv3 COPYING.GPLv3 COPYING.LGPLv2.1 LICENSE.md"
"libvpx|libvpx (VP8/VP9)|BSD-3-Clause + WebM patent grant|https://www.webmproject.org|LICENSE PATENTS"
"svtav1|SVT-AV1 (AV1 encoder)|BSD-3-Clause-Clear + AOMedia patent licence (some files BSD-2-Clause)|https://gitlab.com/AOMediaCodec/SVT-AV1|LICENSE.md LICENSE-BSD2.md PATENTS.md"
"dav1d|dav1d (AV1 decoder)|BSD-2-Clause|https://code.videolan.org/videolan/dav1d|COPYING doc/PATENTS"
"opus|Opus|BSD-3-Clause|https://opus-codec.org|COPYING"
"libogg|libogg|BSD-3-Clause|https://xiph.org/ogg|COPYING"
"libvorbis|libvorbis|BSD-3-Clause|https://xiph.org/vorbis|COPYING"
"libtheora|libtheora|BSD-3-Clause|https://xiph.org/theora|COPYING LICENSE"
"lame|LAME (MP3 encoder)|LGPL-2.0-or-later|https://lame.sourceforge.io|COPYING LICENSE"
"libwebp|libwebp|BSD-3-Clause + WebM patent grant|https://developers.google.com/speed/webp|COPYING PATENTS"
"soxr|SoX Resampler (soxr)|LGPL-2.1-or-later|https://sourceforge.net/projects/soxr|LICENCE COPYING.LGPL"
"zimg|zimg (colour space / scaling)|WTFPL|https://github.com/sekrit-twc/zimg|COPYING"
"freetype|FreeType|FreeType License (FTL; we take the FTL option of FTL/GPLv2)|https://freetype.org|docs/FTL.TXT"
"fribidi|GNU FriBidi|LGPL-2.1-or-later|https://github.com/fribidi/fribidi|COPYING"
"harfbuzz|HarfBuzz|MIT (Old MIT)|https://harfbuzz.github.io|COPYING"
"libass|libass (subtitle renderer)|ISC|https://github.com/libass/libass|COPYING"
"7zip|7-Zip (7zz)|LGPL-2.1-or-later + BSD-3-Clause parts + unRAR licence restriction|https://www.7-zip.org|DOC/License.txt DOC/unRarLicense.txt DOC/copying.txt"
)

component_field() { # entry index -> field (1-based)
    local IFS='|'; local -a f; read -r -a f <<<"$1"; printf '%s' "${f[$(($2 - 1))]}"
}

# ---------------------------------------------------------------- check

# Runs a slice of a universal binary.
run_slice() { local arch="$1"; shift; arch "-$arch" "$@"; }

check_binary() { # path
    local bin="$1" name archs arch deps minos
    name="$(basename "$bin")"
    [[ -x "$bin" ]] || die "$bin missing (run build or fetch)"
    archs="$(lipo -archs "$bin")"
    for arch in "${ARCHS[@]}"; do
        [[ " $archs " == *" $arch "* ]] || die "$name has no $arch slice (has: $archs)"
        deps="$(otool -arch "$arch" -L "$bin" | tail -n +2 | awk '{print $1}')"
        if [ -n "$(grep -v -E '^(/usr/lib/|/System/Library/)' <<<"$deps")" ]; then
            die "$name ($arch) links outside the system: $(grep -v -E '^(/usr/lib/|/System/Library/)' <<<"$deps" | tr '\n' ' ')"
        fi
        minos="$(otool -arch "$arch" -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')"
        [[ -n "$minos" ]] || minos="$(otool -arch "$arch" -l "$bin" | awk '/LC_VERSION_MIN_MACOSX/{f=1} f && /version/{print $2; exit}')"
        [[ "$(printf '%s\n%s\n' "$minos" "$DEPLOYMENT_TARGET" | sort -V | tail -1)" == "$DEPLOYMENT_TARGET" ]] ||
            die "$name ($arch) needs macOS $minos, above $DEPLOYMENT_TARGET"
        if grep -q '/opt/homebrew' <<< "$(strings -a "$bin")"; then die "$name ($arch) mentions /opt/homebrew"; fi
        printf '    %-8s %-6s %s system libraries only, minos %s\n' "$name" "$arch" "$(wc -l <<<"$deps" | tr -d ' ')" "$minos" >&2
    done
}

check_ffmpeg_licence() { # path
    local bin="$1" arch conf lic
    for arch in "${ARCHS[@]}"; do
        conf="$(run_slice "$arch" "$bin" -hide_banner -buildconf 2>&1)"
        grep -q -- '--enable-version3' <<<"$conf" || die "$(basename "$bin") ($arch): not built with --enable-version3"
        grep -q -- '--disable-gpl' <<<"$conf" || die "$(basename "$bin") ($arch): --disable-gpl missing"
        if grep -q -E -- '--enable-(gpl|nonfree|libx264|libx265|libxvid|libfdk-aac|libxavs|libxavs2|libdavs2|libvidstab|librubberband|frei0r|openssl|libaribb24|libsmbclient|libcdio|avisynth|decklink)' <<<"$conf"; then
            die "$(basename "$bin") ($arch): GPL / nonfree option in -buildconf"
        fi
        lic="$(run_slice "$arch" "$bin" -hide_banner -L 2>&1 | tr '\n' ' ')"
        [[ "$lic" == *"GNU Lesser General Public License"*"version 3"* && "$lic" != *"GNU General Public License"*"modify it under the terms of the GNU General"* ]] ||
            die "$(basename "$bin") ($arch): -L does not report LGPL v3 or later: $lic"
    done
    log "    $(basename "$bin"): LGPL-3.0-or-later (-L), no GPL/nonfree options in -buildconf"
}

cmd_check() {
    log "Checking $TOOLS_DIR"
    local b
    for b in "${BINARIES[@]}"; do check_binary "$TOOLS_DIR/$b"; done
    check_ffmpeg_licence "$TOOLS_DIR/ffmpeg"
    check_ffmpeg_licence "$TOOLS_DIR/ffprobe"
}

# ---------------------------------------------------------------- smoke

smoke_ffmpeg() { # arch
    local arch="$1" d="$WORK/smoke-$arch/ffmpeg"
    mkdir -p "$d"
    local ff=(arch "-$arch" "$TOOLS_DIR/ffmpeg" -hide_banner -loglevel error -nostdin -y)
    local fp=(arch "-$arch" "$TOOLS_DIR/ffprobe" -v error -show_entries stream=codec_name -of csv=p=0)
    local video=(-f lavfi -i "testsrc2=size=320x240:rate=25:duration=2")
    local tone=(-f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2")
    local n=0
    expect() { # file "codec codec..." : the streams' codec names, in order
        local got; got="$("${fp[@]}" "$1" | tr '\n' ' ' | sed 's/ $//')"
        [[ "$got" == "$2" ]] || die "[$arch] $(basename "$1"): expected streams '$2', got '$got'"
        n=$((n + 1))
    }
    ffq() { "${ff[@]}" "$@" >"$d/last.log" 2>&1 || { cat "$d/last.log" >&2; die "[$arch] ffmpeg failed: $*"; }; }
    decodes() { ffq "$@" -f null -; }

    # H.264 / HEVC through VideoToolbox, AAC through AudioToolbox
    ffq "${video[@]}" "${tone[@]}" -c:v h264_videotoolbox -b:v 500k -c:a aac_at -b:a 96k "$d/vt.mp4"
    expect "$d/vt.mp4" "h264 aac"; decodes -i "$d/vt.mp4"
    if [[ "$arch" == "$(uname -m)" ]]; then   # Rosetta cannot create a VideoToolbox HEVC session (-12908)
        ffq "${video[@]}" -c:v hevc_videotoolbox -b:v 500k -tag:v hvc1 "$d/vt-hevc.mp4"
        expect "$d/vt-hevc.mp4" "hevc"
    fi
    # VP8 / VP9 (libvpx), AV1 (SVT-AV1 encode, dav1d decode)
    ffq "${video[@]}" -c:v libvpx-vp9 -b:v 300k -deadline realtime -cpu-used 8 "$d/vp9.webm"
    expect "$d/vp9.webm" "vp9"; decodes -c:v libvpx-vp9 -i "$d/vp9.webm"
    ffq "${video[@]}" -c:v libvpx -b:v 300k -deadline realtime -cpu-used 8 "$d/vp8.webm"
    expect "$d/vp8.webm" "vp8"
    ffq "${video[@]}" -c:v libsvtav1 -preset 12 -b:v 300k "$d/av1.mkv"
    expect "$d/av1.mkv" "av1"; decodes -c:v libdav1d -i "$d/av1.mkv"
    ffq "${video[@]}" -c:v libtheora -q:v 6 "$d/theora.ogv"
    expect "$d/theora.ogv" "theora"
    # audio
    ffq "${tone[@]}" -c:a libopus -b:a 64k "$d/tone.opus"
    expect "$d/tone.opus" "opus"; decodes -i "$d/tone.opus"
    ffq "${tone[@]}" -c:a libvorbis -q:a 4 "$d/tone.ogg"
    expect "$d/tone.ogg" "vorbis"
    ffq "${tone[@]}" -c:a libmp3lame -b:a 128k "$d/tone.mp3"
    expect "$d/tone.mp3" "mp3"; decodes -i "$d/tone.mp3"
    # AMR is decoded only (formats §2.7): no AMR encoder is built; the native decoder reads the committed AMR-NB fixture
    if grep -q -i amr <<< "$("${ff[@]:0:3}" -hide_banner -encoders 2>/dev/null)"; then die "[$arch] ffmpeg has an AMR encoder"; fi
    ffq -c:a amrnb -i "$ROOT/Tests/Corpus/generated/media/sample.amr" -c:a pcm_s16le "$d/amr.wav"
    expect "$d/amr.wav" "pcm_s16le"
    ffq "${tone[@]}" -c:a alac "$d/tone.m4a"
    expect "$d/tone.m4a" "alac"
    ffq "${tone[@]}" -af "aresample=resampler=soxr:osr=16000" -c:a pcm_s16le "$d/soxr.wav"
    expect "$d/soxr.wav" "pcm_s16le"
    # GIF with a generated palette, animated WebP, zimg scaling, libass subtitles
    ffq "${video[@]}" -vf "split[a][b];[a]palettegen[p];[b][p]paletteuse" "$d/palette.gif"
    expect "$d/palette.gif" "gif"
    ffq "${video[@]}" -c:v libwebp_anim -loop 0 "$d/anim.webp"
    # ffprobe cannot probe animated WebP (FFmpeg's WebP decoder is still-only), so check the RIFF structure
    [[ "$(head -c 12 "$d/anim.webp" | tail -c 4)" == WEBP ]] && grep -q -a ANMF "$d/anim.webp" || die "[$arch] animated WebP is malformed"
    n=$((n + 1))
    ffq "${video[@]}" -vf "zscale=w=160:h=120:filter=lanczos" -c:v ffv1 "$d/zscale.mkv"
    expect "$d/zscale.mkv" "ffv1"
    printf '[Script Info]\nScriptType: v4.00+\nPlayResX: 320\nPlayResY: 240\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Helvetica,24,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,Super Converter\n' > "$d/sub.ass"
    ffq "${video[@]}" -vf "subtitles=$d/sub.ass" -c:v ffv1 "$d/subbed.mkv"
    expect "$d/subbed.mkv" "ffv1"
    log "    [$arch] ffmpeg: $n conversions ok (H.264 + native-slice HEVC VideoToolbox, AAC AudioToolbox, VP8, VP9, AV1, Theora, Opus, Vorbis, MP3, AMR-NB decode, ALAC, soxr, GIF palette, WebP, zscale, libass)"
}

smoke_7zz() { # arch
    local arch="$1" d="$WORK/smoke-$arch/7zz" fx="$WORK/fixtures"
    mkdir -p "$d"
    local z=(arch "-$arch" "$TOOLS_DIR/7zz")
    local n=0
    same() { cmp -s "$1" "$2" || die "[$arch] $3: extracted file differs"; n=$((n + 1)); }

    # fixtures built from the published layouts: RAR 5, ARJ, FAT12
    mkdir -p "$d/rar" "$d/arj" "$d/fat"
    "${z[@]}" x -y -bso0 -bsp0 -o"$d/rar" "$fx/stored.rar" >/dev/null; same "$d/rar/hello.txt" "$fx/payload/hello.txt" "RAR5"
    "${z[@]}" x -y -bso0 -bsp0 -o"$d/arj" "$fx/stored.arj" >/dev/null; same "$d/arj/hello.txt" "$fx/payload/hello.txt" "ARJ"
    "${z[@]}" x -y -bso0 -bsp0 -o"$d/fat" "$fx/floppy.img" >/dev/null; same "$d/fat/HELLO.TXT" "$fx/payload/hello.txt" "FAT image"

    # archives 7zz writes: encrypted 7z (AES-256, header encryption), AES-256 ZIP, tar, and a wrong password must fail
    local out
    "${z[@]}" a -bso0 -bsp0 -t7z -mhe=on -psecret "$d/aes.7z" "$fx/payload/hello.txt" >/dev/null
    mkdir -p "$d/aes7"; "${z[@]}" x -y -bso0 -bsp0 -psecret -o"$d/aes7" "$d/aes.7z" >/dev/null; same "$d/aes7/hello.txt" "$fx/payload/hello.txt" "AES 7z"
    if "${z[@]}" t -bso0 -bsp0 -pwrong "$d/aes.7z" >/dev/null 2>&1; then die "[$arch] wrong password accepted"; fi
    "${z[@]}" a -bso0 -bsp0 -tzip -mem=AES256 -psecret "$d/aes.zip" "$fx/payload/hello.txt" >/dev/null
    mkdir -p "$d/aesz"; "${z[@]}" x -y -bso0 -bsp0 -psecret -o"$d/aesz" "$d/aes.zip" >/dev/null; same "$d/aesz/hello.txt" "$fx/payload/hello.txt" "AES zip"
    "${z[@]}" a -bso0 -bsp0 -ttar "$d/p.tar" "$fx/payload/hello.txt" >/dev/null
    mkdir -p "$d/tar"; "${z[@]}" x -y -bso0 -bsp0 -o"$d/tar" "$d/p.tar" >/dev/null; same "$d/tar/hello.txt" "$fx/payload/hello.txt" "tar"
    out="$("${z[@]}" l -slt "$d/aes.zip" -psecret | grep -c 'AES-256')" || true
    [[ "$out" -ge 1 ]] || die "[$arch] zip is not AES-256"
    log "    [$arch] 7zz: $n archive checks ok (extract RAR5 / ARJ / FAT image; write+extract AES-256 7z, AES-256 ZIP, tar; wrong password rejected)"
}

cmd_smoke() { # [ffmpeg|7zz]: only that tool
    local only="${1:-}"
    make_work
    mkdir -p "$WORK/fixtures"
    python3 -I "$ROOT/scripts/make-archive-fixtures.py" "$WORK/fixtures"
    local arch
    for arch in "${ARCHS[@]}"; do
        log "Smoke tests ($arch)"
        if [[ -z "$only" || "$only" == ffmpeg ]]; then smoke_ffmpeg "$arch"; fi
        if [[ -z "$only" || "$only" == 7zz ]]; then smoke_7zz "$arch"; fi
    done
}

# ---------------------------------------------------------------- licences and notices

cmd_licenses() { # dir
    local dest="$1" entry id files f
    for entry in "${COMPONENTS[@]}"; do
        id="$(component_field "$entry" 1)"; files="$(component_field "$entry" 5)"
        fetch_source "$id"
        local tmp="$WORK/lic-$id"; mkdir -p "$tmp" "$dest/$id"
        tar -xf "$SRC_PATH" -C "$tmp"
        local top="$tmp"
        [[ "$id" == 7zip ]] || top="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
        for f in $files; do
            [[ -f "$top/$f" ]] || die "$id: licence file $f not found in $SRC_FILE"
            cp "$top/$f" "$dest/$id/$(basename "$f")"
        done
    done
}

notices_section() {
    local lic="$WORK/licenses"
    cmd_licenses "$lic"
    local entry id name spdx home files f
    cat <<'EOF'
## Bundled executables (`Contents/Helpers/`)

Super Converter itself is MIT-licensed. It ships three **separate command-line programs** built from unmodified
upstream source: `ffmpeg`, `ffprobe` (FFmpeg, with the libraries below linked statically into them) and `7zz`
(7-Zip). They are not linked into the app; the app starts them as child processes, like any other tool.

### Licence compliance (LGPL)

- **FFmpeg is licensed LGPL-3.0-or-later as a whole.** The build uses `--enable-version3 --disable-gpl
  --disable-nonfree`; no GPL or non-free component is compiled in (no x264, x265, Xvid, fdk-aac, libxavs, rubberband,
  OpenSSL). `ffmpeg -L` and `ffmpeg -buildconf` show this, and `scripts/tools.sh check` fails the build otherwise.
  No AMR encoder is built (formats §2.7); AMR is read by FFmpeg's own decoders.
- **7-Zip** is LGPL-2.1-or-later with BSD-3-Clause parts and the **unRAR licence restriction** (below).
- **Complete corresponding source.** Every upstream source archive, exactly as downloaded and checked against the
  SHA-256 below, the build scripts (`scripts/build-ffmpeg.sh`, `scripts/build-7zz.sh`, `scripts/tools-common.sh`,
  `scripts/tools.sh`) and `Tools.lock` are published as the release asset `tools-sources.tar.gz` next to the binaries
  (GitHub Releases of `udsy19/super-converter`, tag `tools-*`, listed in `Tools.lock`). No upstream source is modified;
  the scripts only choose configure options and compiler flags.
- **Written offer.** For at least three years after you receive Super Converter we will give anyone, on request and
  for no more than the cost of physically providing it, a copy of that complete corresponding source (open an issue
  at https://github.com/udsy19/super-converter/issues).
- **You may replace these programs.** They are ordinary Mach-O executables in `Contents/Helpers/`. Build your own
  with the published scripts (`scripts/build-ffmpeg.sh build`) and put the result in their place; macOS requires
  replaced code to carry a signature (`codesign --force --sign - <file>`).

### unRAR licence restriction (7-Zip)

`7zz` contains the unRAR decoder (`CPP/7zip/Compress/Rar*`) under the "GNU LGPL with unRAR license restriction".
Super Converter uses it **only to read RAR archives**. The code cannot create RAR archives and must not be used to
develop a RAR (WinRAR)-compatible archiver; RAR output in Super Converter requires the user's own licensed `rar`.
The unRAR sources are unmodified; the licence also forbids charging a fee for the distribution of unRAR itself
(clause 3), so `7zz` is never sold or licensed separately. The licence text is reproduced below.

### Components

| Component | Version | Licence | Source archive (SHA-256) |
|---|---|---|---|
EOF
    for entry in "${COMPONENTS[@]}"; do
        id="$(component_field "$entry" 1)"; name="$(component_field "$entry" 2)"; spdx="$(component_field "$entry" 3)"
        home="$(component_field "$entry" 4)"
        lock_source "$id"
        printf '| [%s](%s) | %s | %s | `%s`<br>`%s` |\n' "$name" "$home" "$SRC_VERSION" "$spdx" "$SRC_FILE" "$SRC_SHA"
    done
    cat <<'EOF'

Where each is used. `ffmpeg`/`ffprobe`: FFmpeg with VideoToolbox and AudioToolbox (macOS system frameworks, not
redistributed), libvpx (VP8/VP9), SVT-AV1 (AV1 encode), dav1d (AV1 decode), libtheora + libogg (Theora/Ogg), libopus
(Opus), libvorbis (Vorbis), LAME (MP3 encode), libwebp (WebP, animated WebP), soxr (resampling), zimg (colour-space
conversion and scaling), libass with HarfBuzz, FreeType and FriBidi (subtitle rendering; fonts come from CoreText), and
the system zlib, bzip2 and iconv. AMR-NB and AMR-WB are decoded by FFmpeg itself; nothing encodes AMR.
`7zz`: 7-Zip 25.01 (arm64 with its assembler routines, x86_64 portable C).

### Licence texts
EOF
    for entry in "${COMPONENTS[@]}"; do
        id="$(component_field "$entry" 1)"; name="$(component_field "$entry" 2)"; files="$(component_field "$entry" 5)"
        printf '\n#### %s\n' "$name"
        for f in $files; do
            printf '\n`%s`\n\n```text\n' "$f"
            tr -d '\r' < "$lic/$id/$(basename "$f")"   # 7-Zip's texts have DOS line ends
            printf '\n```\n'
        done
    done
}

NOTICES_FILE="$ROOT/THIRD_PARTY_NOTICES.md"
NOTICES_BEGIN="<!-- BEGIN bundled-executables (generated by scripts/tools.sh notices write) -->"
NOTICES_END="<!-- END bundled-executables -->"

cmd_notices() { # [write|check]
    make_work
    local mode="${1:-print}" section="$WORK/section.md"
    { printf '%s\n\n' "$NOTICES_BEGIN"; notices_section; printf '\n%s\n' "$NOTICES_END"; } > "$section"
    case "$mode" in
        print) cat "$section" ;;
        write|check)
            local merged="$WORK/notices.md"
            if grep -q -F "$NOTICES_BEGIN" "$NOTICES_FILE" 2>/dev/null; then
                awk -v b="$NOTICES_BEGIN" -v e="$NOTICES_END" -v sec="$section" '
                    $0 == b { while ((getline line < sec) > 0) print line; skip = 1; next }
                    $0 == e { skip = 0; next }
                    !skip' "$NOTICES_FILE" > "$merged"
            else
                {
                    if [[ -f "$NOTICES_FILE" ]]; then cat "$NOTICES_FILE"; echo
                    else printf '# Third-party notices\n\n'; fi
                    cat "$section"
                } > "$merged"
            fi
            if [[ "$mode" == write ]]; then cp "$merged" "$NOTICES_FILE"; log "Wrote $NOTICES_FILE"
            else cmp -s "$merged" "$NOTICES_FILE" || die "THIRD_PARTY_NOTICES.md is stale (run scripts/tools.sh notices write)"; fi ;;
        *) die "usage: $0 notices [write|check]" ;;
    esac
}

# ---------------------------------------------------------------- package, release, fetch

cmd_package() {
    make_work
    local b
    for b in "${BINARIES[@]}"; do [[ -x "$TOOLS_DIR/$b" ]] || die "$TOOLS_DIR/$b missing (run build first)"; done
    local pkg="$WORK/pkg"
    mkdir -p "$pkg/Tools" "$DIST"
    for b in "${BINARIES[@]}"; do cp "$TOOLS_DIR/$b" "$pkg/Tools/"; done
    cmd_licenses "$pkg/Tools/Licenses"
    rm -f "$DIST/$BIN_ASSET"
    (cd "$pkg" && ditto -c -k --keepParent Tools "$DIST/$BIN_ASSET")

    local src="$WORK/src-bundle/tools-sources"
    mkdir -p "$src/sources" "$src/scripts"
    local entry id
    for id in nasm ffmpeg $(printf '%s\n' "${COMPONENTS[@]}" | cut -d'|' -f1); do
        fetch_source "$id"; cp "$SRC_PATH" "$src/sources/"
    done
    cp "$ROOT"/scripts/{tools-common.sh,tools.sh,build-ffmpeg.sh,build-7zz.sh,make-archive-fixtures.py} "$src/scripts/"
    cp "$LOCK" "$src/Tools.lock"
    rm -f "$DIST/$SRC_ASSET"
    tar -czf "$DIST/$SRC_ASSET" -C "$WORK/src-bundle" tools-sources
    log "$BIN_ASSET: $(du -h "$DIST/$BIN_ASSET" | cut -f1), sha256 $(sha256_of "$DIST/$BIN_ASSET")"
    log "$SRC_ASSET: $(du -h "$DIST/$SRC_ASSET" | cut -f1), sha256 $(sha256_of "$DIST/$SRC_ASSET")"
}

cmd_release() {
    make_work
    local tag="${1:-tools-$(date +%Y-%m-%d)}"
    [[ -f "$DIST/$BIN_ASSET" && -f "$DIST/$SRC_ASSET" ]] || die "run package first"
    if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
        gh release upload "$tag" "$DIST/$BIN_ASSET" "$DIST/$SRC_ASSET" --repo "$REPO" --clobber
    else
        gh release create "$tag" "$DIST/$BIN_ASSET" "$DIST/$SRC_ASSET" --repo "$REPO" --prerelease \
            --title "Bundled executables $tag" --notes \
"Universal (arm64 + x86_64, macOS 14+) \`ffmpeg\`, \`ffprobe\` (LGPL-3.0-or-later build) and \`7zz\` (7-Zip), built by scripts/build-ffmpeg.sh and scripts/build-7zz.sh. \`$SRC_ASSET\` is the complete corresponding source (all upstream tarballs, build scripts, Tools.lock). Licences: Tools/Licenses inside \`$BIN_ASSET\` and THIRD_PARTY_NOTICES.md. Fetched by scripts/tools.sh fetch, pinned by SHA-256 in Tools.lock. Not an app release."
    fi
    lock_set release - "$tag"
    lock_set asset "$BIN_ASSET" "$(sha256_of "$DIST/$BIN_ASSET")"
    lock_set asset "$SRC_ASSET" "$(sha256_of "$DIST/$SRC_ASSET")"
    log "Published $tag; Tools.lock updated (commit it)"
}

cmd_fetch() {
    make_work
    local tag sum
    tag="$(lock_value release)"; sum="$(lock_asset "$BIN_ASSET")"
    [[ -n "$tag" && -n "$sum" ]] || die "release/asset pins missing in Tools.lock"
    log "Fetching $REPO $tag/$BIN_ASSET"
    gh release download "$tag" --repo "$REPO" --pattern "$BIN_ASSET" --dir "$WORK"
    verify_sha "$WORK/$BIN_ASSET" "$sum" "$BIN_ASSET (pinned in Tools.lock)"
    mkdir -p "$ROOT/Vendor"
    rm -rf "$TOOLS_DIR"
    ditto -x -k "$WORK/$BIN_ASSET" "$ROOT/Vendor"
    log "Installed $TOOLS_DIR"
    cmd_check
}

case "${1:-}" in
    check) cmd_check ;;
    smoke) shift; cmd_smoke "$@" ;;
    package) cmd_package ;;
    release) shift; cmd_release "$@" ;;
    fetch) cmd_fetch ;;
    licenses) make_work; cmd_licenses "${2:?usage: $0 licenses <dir>}" ;;
    notices) shift; cmd_notices "$@" ;;
    *) die "usage: $0 check|smoke|package|release [tag]|fetch|licenses <dir>|notices" ;;
esac
