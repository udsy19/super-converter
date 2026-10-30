#!/bin/bash
# Super Converter installer.
#
#   Install / update:  curl -fsSL https://udsy19.github.io/super-converter/install.sh | bash
#   Uninstall:         curl -fsSL https://udsy19.github.io/super-converter/install.sh | bash -s -- --uninstall
#
# Downloads the latest release from GitHub, checks it against the SHA-256 in the release notes (the line the app's own
# updater checks, scripts/release.sh) and its code signature, installs it into /Applications (or ~/Applications when
# /Applications isn't writable) and opens it. Nothing else on your system is changed.
# Options (environment): SUPERCONVERTER_INSTALL_DIR=<folder> to install elsewhere, SUPERCONVERTER_NO_OPEN=1 to skip launching.
# Adapted from super-paste scripts/install.sh: names, the checksum and the signature check.
set -euo pipefail

REPO="udsy19/super-converter"
APP="Super Converter.app"
DMG_URL="https://github.com/$REPO/releases/latest/download/SuperConverter.dmg"

bold=$'\033[1m'; dim=$'\033[2m'; green=$'\033[32m'; red=$'\033[31m'; reset=$'\033[0m'
say()  { printf '%s\n' "$*"; }
step() { printf '%s→%s %s\n' "$bold" "$reset" "$*"; }
fail() { printf '%s✗ %s%s\n' "$red" "$*" "$reset" >&2; exit 1; }

# Asks a running copy to quit and waits up to five seconds for it.
quit_running() {
  pgrep -x SuperConverter >/dev/null 2>&1 || return 0
  step "Quitting the running copy of Super Converter"
  osascript -e 'tell application id "com.udsy.superconverter" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x SuperConverter >/dev/null 2>&1 || return 0; sleep 0.5; done
  fail "Super Converter is still running (it may be converting). Quit it from its menu and run the installer again."
}

# Every installed copy, one path per line.
installed_paths() {
  for dir in "/Applications" "$HOME/Applications"; do
    [ -d "$dir/$APP" ] && printf '%s\n' "$dir/$APP"
  done
  return 0
}

[ "$(uname -s)" = "Darwin" ] || fail "Super Converter runs on macOS only."

if [ "${1:-}" = "--uninstall" ]; then
  paths="$(installed_paths)"
  [ -n "$paths" ] || fail "Super Converter isn't installed."
  quit_running
  while IFS= read -r path; do
    step "Removing $path"
    rm -rf "$path"
  done <<< "$paths"
  say "${green}✓ Super Converter was uninstalled.${reset}"
  say "${dim}Its helpers and settings were kept in ~/Library/Application Support/Super Converter, ~/Library/Caches/Super${reset}"
  say "${dim}Converter and ~/Library/Preferences/com.udsy.superconverter.plist — delete them to remove everything.${reset}"
  exit 0
fi

major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || fail "Super Converter needs macOS 14 Sonoma or later (you have $(sw_vers -productVersion))."

say "${bold}Installing Super Converter${reset} ${dim}— drop any file, get any format, on your Mac${reset}"
tmp="$(mktemp -d -t superconverter-install)"
mnt="$tmp/mount"
cleanup() { hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

step "Downloading the latest release"
curl -fL --progress-bar -o "$tmp/SuperConverter.dmg" "$DMG_URL" || fail "Download failed — check your connection and try again."

step "Verifying the disk image"
# The release notes end with "SHA-256 (SuperConverter.dmg): `<hex>`". If GitHub's API can't be reached (it limits
# anonymous requests), the image and signature checks below still run.
expected="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
  | grep -oE 'SHA-256 \(SuperConverter\.dmg\): `?[0-9a-f]{64}' | grep -oE '[0-9a-f]{64}' | head -1 || true)"
if [ -n "$expected" ]; then
  actual="$(shasum -a 256 "$tmp/SuperConverter.dmg" | cut -d' ' -f1)"
  [ "$actual" = "$expected" ] || fail "The download doesn't match the SHA-256 in the release notes. Please try again."
else
  say "${dim}  Couldn't read the release's SHA-256 from GitHub; checking the image and its signature only.${reset}"
fi
hdiutil verify "$tmp/SuperConverter.dmg" -quiet || fail "The download is damaged. Please try again."
mkdir -p "$mnt"
hdiutil attach "$tmp/SuperConverter.dmg" -nobrowse -readonly -mountpoint "$mnt" -quiet || fail "Couldn't open the disk image."
[ -d "$mnt/$APP" ] || fail "The disk image doesn't contain $APP."
codesign --verify --deep --strict "$mnt/$APP" 2>/dev/null || fail "$APP in the disk image isn't validly signed."

dest="${SUPERCONVERTER_INSTALL_DIR:-/Applications}"
mkdir -p "$dest" 2>/dev/null || true
if [ ! -w "$dest" ]; then
  dest="$HOME/Applications"; mkdir -p "$dest"
fi

[ "${SUPERCONVERTER_NO_OPEN:-0}" = 1 ] || quit_running
step "Installing to $dest"
rm -rf "$dest/$APP"
ditto "$mnt/$APP" "$dest/$APP"
# Downloads made with curl aren't quarantined; clear the flag anyway in case the image was cached by a browser.
xattr -dr com.apple.quarantine "$dest/$APP" 2>/dev/null || true

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$dest/$APP/Contents/Info.plist" 2>/dev/null || echo "")"
if [ "${SUPERCONVERTER_NO_OPEN:-0}" = 1 ]; then
  say "${green}✓ Super Converter ${version} is installed in $dest.${reset}"
else
  say "${green}✓ Super Converter ${version} is installed.${reset} Opening it now — drop any file on its window."
  open "$dest/$APP"
fi
