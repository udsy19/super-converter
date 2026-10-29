#!/bin/bash
# Builds build/Super Converter.app (release by default; `--debug` for a fast debug build; UNIVERSAL=1 for Apple silicon +
# Intel) and signs it inside out with the project-local identity from scripts/signing-setup.sh (ad hoc when there is none).
#
#   Contents/MacOS/SuperConverter         the app (swift build --product SuperConverter)
#   Contents/Helpers/{ffmpeg,ffprobe,7zz}  the bundled LGPL FFmpeg and 7-Zip from Vendor/Tools (scripts/tools.sh fetch)
#   Contents/Frameworks/libraw_r.dylib     LibRaw (LGPL, dynamic) from Vendor/LibRaw.xcframework (scripts/fetch-vendor.sh)
#   Contents/PlugIns/<action>.appex        the six Finder Quick Actions (ux §5.10): one executable, SuperConverterQuickActions,
#                                          entered through NSExtensionMain, each with MenuBarKit's Info.plist from
#                                          Sources/SuperConverterQuickActions/Plists; sandboxed
#   Contents/Resources                     the icon (scripts/make-icon.swift), TypesetKit's fonts, the licences and notices
#   Contents/Info.plist                    Resources/Info.plist, written from Core's catalog by the self-test
#
# The script ends with static launch checks (nothing is launched and no window opens): signatures, entitlements, rpaths,
# every @rpath dependency present, executables and entry points, the extensions, helpers, resources and Info.plist.
# Adapted from super-pdf scripts/build-app.sh (commit 2079863): bundled executables and the LibRaw dylib added, the four
# Super PDF Quick Actions replaced by Super Converter's six, the checks fitted to this app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
CONFIG=release; [ "${1:-}" = "--debug" ] && CONFIG=debug
APP_EXE=SuperConverter
EXT_EXE=SuperConverterQuickActions
PRODUCTS=("$APP_EXE" "$EXT_EXE")
TOOLS=(ffmpeg ffprobe 7zz)
LIBRAW="$ROOT/Vendor/LibRaw.xcframework/macos-arm64_x86_64/libraw_r.dylib"
for tool in "${TOOLS[@]}"; do
  [ -x "$ROOT/Vendor/Tools/$tool" ] || { echo "error: Vendor/Tools/$tool is missing; run scripts/tools.sh fetch" >&2; exit 1; }
done
[ -f "$LIBRAW" ] || { echo "error: Vendor/LibRaw.xcframework is missing; run scripts/fetch-vendor.sh" >&2; exit 1; }
if [ "${UNIVERSAL:-0}" = 1 ]; then
  # Build each architecture separately (the CLT toolchain has no multi-arch build) and merge with lipo. The vendor
  # libraries and bundled executables are universal already. The Command Line Tools ship the Swift back-deployment
  # compatibility libraries for arm64 only; macOS 14 has everything they back-deploy, so skip them.
  for arch in arm64 x86_64; do
    for product in "${PRODUCTS[@]}"; do
      swift build -c "$CONFIG" --product "$product" --triple "$arch-apple-macosx14.0" -Xswiftc -runtime-compatibility-version -Xswiftc none
    done
  done
  ARM="$(swift build -c "$CONFIG" --triple arm64-apple-macosx14.0 --show-bin-path)"
  INTEL="$(swift build -c "$CONFIG" --triple x86_64-apple-macosx14.0 --show-bin-path)"
  BIN="$ROOT/build/universal"; mkdir -p "$BIN"; RES_BIN="$ARM"
  for product in "${PRODUCTS[@]}"; do lipo -create -output "$BIN/$product" "$ARM/$product" "$INTEL/$product"; done
else
  for product in "${PRODUCTS[@]}"; do swift build -c "$CONFIG" --product "$product"; done
  BIN="$(swift build -c "$CONFIG" --show-bin-path)"; RES_BIN="$BIN"
fi

APP="$ROOT/build/Super Converter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" "$APP/Contents/PlugIns" "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp "$BIN/$APP_EXE" "$APP/Contents/MacOS/$APP_EXE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"

# Bundled executables and LibRaw (ARCHITECTURE §7), with their licence texts (LGPL: the notices say where the source is).
for tool in "${TOOLS[@]}"; do cp "$ROOT/Vendor/Tools/$tool" "$APP/Contents/Helpers/$tool"; done
cp "$LIBRAW" "$APP/Contents/Frameworks/"
cp -R "$ROOT/Vendor/Tools/Licenses" "$APP/Contents/Resources/Licenses/Tools"
cp -R "$ROOT/Vendor/LibRaw.xcframework/Licenses" "$APP/Contents/Resources/Licenses/LibRaw"

# Licences and notices (Settings › About reads THIRD_PARTY_NOTICES.md from here), TypesetKit's fonts and hyphenation
# patterns and MathKit's MathJax (Contents/Resources/{Fonts,Hyphenation,MathJax}, each with its own licences) and any
# SwiftPM resource bundles where Bundle.module looks.
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"
for dir in Fonts Hyphenation MathJax; do cp -R "$ROOT/Resources/$dir" "$APP/Contents/Resources/$dir"; done
find "$RES_BIN" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

# The Quick Actions: one bundle per action around the shared executable, its version the app's.
EXTENSIONS=()
for plist in "$ROOT"/Sources/SuperConverterQuickActions/Plists/*.plist; do
  name="$(basename "$plist" .plist)"
  ext="$APP/Contents/PlugIns/$name.appex"
  mkdir -p "$ext/Contents/MacOS"
  cp "$BIN/$EXT_EXE" "$ext/Contents/MacOS/$EXT_EXE"
  cp "$plist" "$ext/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$ext/Contents/Info.plist"
  EXTENSIONS+=("$ext")
done

# rpaths: SwiftPM adds build-tree and toolchain rpaths; the bundle needs none of them (Swift comes from /usr/lib/swift),
# and the app finds libraw_r.dylib in Contents/Frameworks.
for exe in "$APP/Contents/MacOS/$APP_EXE" "${EXTENSIONS[@]/%//Contents/MacOS/$EXT_EXE}"; do
  while IFS= read -r rpath; do
    [ -n "$rpath" ] && install_name_tool -delete_rpath "$rpath" "$exe" 2>/dev/null || true
  done < <(otool -l "$exe" | awk '/LC_RPATH/ {getline; getline; print $2}' | grep -E '\.build/|CommandLineTools|Xcode|^@loader_path$' || true)
done
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$APP_EXE"

# The icon, re-rendered when the script changes.
ICONS="$ROOT/build/icons"
if [ ! -f "$ICONS/AppIcon.icns" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICONS/AppIcon.icns" ]; then
  rm -rf "$ICONS"
  swift "$ROOT/scripts/make-icon.swift" "$ICONS" && iconutil -c icns "$ICONS/AppIcon.iconset" -o "$ICONS/AppIcon.icns"
fi
cp "$ICONS/AppIcon.icns" "$APP/Contents/Resources/"

# Signing, nested code first: the helpers and LibRaw, then the extensions, then the bundle that seals them. Everything
# gets the hardened runtime; the helpers keep their own identifiers.
KC="$ROOT/.signing/super-converter.keychain-db"
ENT="$ROOT/Resources/SuperConverter.entitlements"
EXT_ENT="$ROOT/Resources/QuickActions.entitlements"
IDENTITY="Super Converter Local Signing"
NESTED=("$APP/Contents/Frameworks/libraw_r.dylib")
for tool in "${TOOLS[@]}"; do NESTED+=("$APP/Contents/Helpers/$tool"); done
sign() { codesign -f -s "$SIGN_AS" ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} -o runtime "$@"; }
if [ -f "$KC" ]; then
  SIGN_AS="$IDENTITY"; KEYCHAIN=(--keychain "$KC")
  security unlock-keychain -p superconverter "$KC"
  ORIG=()
  while IFS= read -r line; do line="${line#"${line%%[![:space:]]*}"}"; line="${line//\"/}"; [ -n "$line" ] && ORIG+=("$line"); done < <(security list-keychains -d user)
  # The project keychain joins the search list only while codesign runs; the trap puts the user's list back even
  # when signing fails.
  restore() { security list-keychains -d user -s "${ORIG[@]}"; }
  trap restore EXIT
  security list-keychains -d user -s "${ORIG[@]}" "$KC"
else
  echo "warning: no project signing identity (run scripts/signing-setup.sh); signing ad hoc, so automation grants won't survive rebuilds and the updater can't verify updates" >&2
  SIGN_AS="-"; KEYCHAIN=()
fi
for item in "${NESTED[@]}"; do sign "$item"; done
for ext in "${EXTENSIONS[@]}"; do sign --entitlements "$EXT_ENT" "$ext"; done
sign --entitlements "$ENT" "$APP"
if [ -f "$KC" ]; then restore; trap - EXIT; fi
codesign --verify --deep --strict "$APP"

# ---- Static launch checks. The app is never launched here (no GUI on a build machine); instead everything that would
# make it abort at launch, or lose a feature silently, is checked on disk.
fail() { echo "error: $*" >&2; exit 1; }
EXE="$APP/Contents/MacOS/$APP_EXE"
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
# LibRaw is signed without an Apple Team ID, so the hardened runtime refuses to load it unless library validation is
# off. Without this the app aborts at launch; fail the build instead.
grep -q disable-library-validation <<< "$ENTITLEMENTS" || fail "$APP embeds libraw_r.dylib but lacks com.apple.security.cs.disable-library-validation"
grep -q com.apple.security.automation.apple-events <<< "$ENTITLEMENTS" || fail "entitlement com.apple.security.automation.apple-events missing (iWork and Office automation)"
if grep -q com.apple.security.app-sandbox <<< "$ENTITLEMENTS"; then fail "the app must not be sandboxed (helpers, automation and hdiutil need it)"; fi
# Executables and their dependencies: no rpath or library in the build tree or the toolchain, every @rpath dependency
# inside Contents/Frameworks.
BINARIES=("$EXE" "${NESTED[@]}")
for ext in "${EXTENSIONS[@]}"; do BINARIES+=("$ext/Contents/MacOS/$EXT_EXE"); done
for bin in "${BINARIES[@]}"; do
  [ -f "$bin" ] || fail "missing $bin"
  [[ "$bin" == *.dylib ]] || [ -x "$bin" ] || fail "$bin is not executable"
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    [ "$dep" = "$(otool -D "$bin" 2>/dev/null | awk 'NR == 2')" ] && continue   # a library's own install name
    rel="${dep#@rpath/}"
    [ -e "$APP/Contents/Frameworks/$rel" ] || fail "$(basename "$bin") depends on $dep, which is not in Contents/Frameworks"
  done < <(otool -L "$bin" | awk 'NR > 1 && $1 ~ /^@rpath\// { print $1 }' | sort -u)
  if grep -qE '\.build/|CommandLineTools|Xcode|/opt/homebrew|/usr/local' <<< "$(otool -L "$bin" | awk 'NR > 1 { print $1 }')"; then
    fail "$(basename "$bin") links outside the bundle and the system"
  fi
  if grep -qE '\.build/|CommandLineTools|Xcode' <<< "$(otool -l "$bin" | awk '/LC_RPATH/ {getline; getline; print $2}')"; then
    fail "$(basename "$bin") has a build-tree rpath"
  fi
  codesign --verify --strict "$bin" 2>/dev/null || fail "$(basename "$bin") is not signed"
done
otool -l "$EXE" | grep -q '@executable_path/../Frameworks' || fail "the app has no rpath into Contents/Frameworks"
# Info.plist: well formed, the executable, the bundle id, the URL scheme, document types for every kind, the Services
# entries, every usage string.
for plist in "$APP/Contents/Info.plist" "${EXTENSIONS[@]/%//Contents/Info.plist}"; do plutil -lint -s "$plist" || fail "$plist is not a valid property list"; done
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist" 2>/dev/null; }
[ "$(plist CFBundleExecutable)" = "$APP_EXE" ] || fail "CFBundleExecutable is not $APP_EXE"
[ "$(plist CFBundleIdentifier)" = "com.udsy.superconverter" ] || fail "CFBundleIdentifier is not com.udsy.superconverter"
[ "$(plist :CFBundleURLTypes:0:CFBundleURLSchemes:0)" = "superconverter" ] || fail "the superconverter:// scheme is not registered"
[ "$(plutil -extract CFBundleDocumentTypes raw "$APP/Contents/Info.plist")" -eq 12 ] || fail "expected 12 document types (11 kinds and other files)"
[ "$(plutil -extract NSServices raw "$APP/Contents/Info.plist")" -eq 6 ] || fail "expected six Services entries"
for key in NSAppleEventsUsageDescription NSDesktopFolderUsageDescription NSDocumentsFolderUsageDescription NSDownloadsFolderUsageDescription \
           NSRemovableVolumesUsageDescription NSNetworkVolumesUsageDescription; do
  plist "$key" >/dev/null || fail "Info.plist lacks $key"
done
# The Quick Actions: sandboxed extensions entered through NSExtensionMain, ids under the app's, versions the app's.
[ ${#EXTENSIONS[@]} -eq 6 ] || fail "expected six Quick Action extensions, found ${#EXTENSIONS[@]}"
grep -q '_OBJC_CLASS_\$_QuickActionRequestHandler' <<< "$(nm -m "$BIN/$EXT_EXE")" || fail "the Quick Actions have no QuickActionRequestHandler class"
for ext in "${EXTENSIONS[@]}"; do
  info() { /usr/libexec/PlistBuddy -c "Print $1" "$ext/Contents/Info.plist" 2>/dev/null; }
  [ "$(info :NSExtension:NSExtensionPointIdentifier)" = "com.apple.services" ] || fail "$(basename "$ext"): not an action extension"
  [ "$(info :NSExtension:NSExtensionPrincipalClass)" = "QuickActionRequestHandler" ] || fail "$(basename "$ext"): wrong principal class"
  [[ "$(info CFBundleIdentifier)" == com.udsy.superconverter.quickactions.* ]] || fail "$(basename "$ext"): its bundle id isn't under the app's"
  [ "$(info CFBundleShortVersionString)" = "$VERSION" ] && [ "$(info CFBundleVersion)" = "$BUILD" ] || fail "$(basename "$ext"): version differs from the app's"
  info SuperConverterQuickAction >/dev/null || fail "$(basename "$ext"): no SuperConverterQuickAction key"
  grep -q LC_MAIN <<< "$(otool -l "$ext/Contents/MacOS/$EXT_EXE")" || fail "$(basename "$ext"): no entry point"
  grep -q '(undefined) external _NSExtensionMain' <<< "$(nm -m "$ext/Contents/MacOS/$EXT_EXE")" || fail "$(basename "$ext"): not entered through NSExtensionMain"
  grep -q com.apple.security.app-sandbox <<< "$(codesign -d --entitlements :- "$ext" 2>/dev/null)" || fail "$(basename "$ext"): not sandboxed"
done
# The bundled FFmpeg must be the LGPL build (formats §2): never one configured with GPL or non-free parts.
if grep -qE -- '--enable-(gpl|nonfree)' <<< "$("$APP/Contents/Helpers/ffmpeg" -hide_banner -buildconf 2>/dev/null)"; then
  fail "Contents/Helpers/ffmpeg was built with --enable-gpl or --enable-nonfree"
fi
# Resources the app expects at run time.
for res in Resources/AppIcon.icns Resources/LICENSE Resources/THIRD_PARTY_NOTICES.md Resources/Fonts/LatinModern \
           Resources/Fonts/LatinModernMath Resources/Hyphenation Resources/MathJax Resources/Licenses/Tools Resources/Licenses/LibRaw PkgInfo; do
  [ -e "$APP/Contents/$res" ] || fail "missing $res in the bundle"
done
echo "Static launch checks passed: signatures, entitlements, rpaths, dependencies, entry points, Quick Actions, helpers, resources, Info.plist"
echo "Built $APP"
