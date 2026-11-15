#!/bin/sh
# Download the latest klzgrad/naiveproxy static build for this router's
# OpenWrt architecture and install the binary to /usr/bin/naive.
# The binary is not shipped in the aurora-router-panel package (~13 MB).
#
# Usage:
#   install-naive.sh [--force] [version|url]
#     --force     replace an existing /usr/bin/naive
#     version     release tag, e.g. v154.0.8037.49-5 (default: latest)
#     url         direct https URL to a naiveproxy-*-openwrt-*.tar.xz
#
# Needs: curl, and xz (or unxz). On OpenWrt: opkg install xz
# Does not overwrite /etc/naive/config.json.
set -eu

DEST=/usr/bin/naive
REPO=klzgrad/naiveproxy
API=https://api.github.com/repos/$REPO/releases/latest
FORCE=0
ARG=""

usage() {
	sed -n '2,16p' "$0" | sed 's/^# \?//'
	exit 1
}

err() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) usage ;;
		--force) FORCE=1 ;;
		-*) err "unknown option $1" ;;
		*) [ -z "$ARG" ] || err "unexpected argument $1"; ARG=$1 ;;
	esac
	shift
done

if [ -x "$DEST" ] && [ "$FORCE" != 1 ]; then
	echo "naive is already installed: $DEST"
	"$DEST" --version 2>/dev/null || true
	echo "To reinstall, run: $0 --force"
	exit 0
fi

command -v curl >/dev/null 2>&1 || err "curl is required"
if command -v xz >/dev/null 2>&1; then
	unxz_c() { xz -dc "$1"; }
elif command -v unxz >/dev/null 2>&1; then
	unxz_c() { unxz -c "$1"; }
else
	err "xz is required to unpack the archive (opkg update && opkg install xz)"
fi

detect_arch() {
	if [ -f /etc/openwrt_release ]; then
		# shellcheck disable=SC1091
		. /etc/openwrt_release
		if [ -n "${DISTRIB_ARCH:-}" ]; then
			echo "$DISTRIB_ARCH"
			return 0
		fi
	fi
	case "$(uname -m)" in
		aarch64|arm64) echo aarch64_cortex-a53 ;;
		armv7l|armv7*) echo arm_cortex-a7_neon-vfpv4 ;;
		x86_64|amd64) echo x86_64 ;;
		i386|i686) echo x86 ;;
		riscv64) echo riscv64 ;;
		mipsel) echo mipsel_24kc ;;
		*) return 1 ;;
	esac
}

ARCH=$(detect_arch) || err "could not detect the router architecture"
echo "Architecture: $ARCH"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if echo "$ARG" | grep -qE '^https://'; then
	URL=$ARG
	echo "Downloading $URL"
else
	if [ -n "$ARG" ]; then
		TAG=$ARG
	else
		echo "Fetching the latest release of $REPO..."
		JSON=$TMP/latest.json
		curl -fsSL --max-time 25 -o "$JSON" "$API" \
			|| err "could not reach the GitHub API. Download the archive by hand and run: $0 <url>"
		if command -v jq >/dev/null 2>&1; then
			TAG=$(jq -r .tag_name "$JSON")
		else
			TAG=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$JSON" | head -1)
		fi
		[ -n "$TAG" ] && [ "$TAG" != null ] || err "could not read the release tag"
	fi
	echo "Release: $TAG"
	BASE=https://github.com/$REPO/releases/download/$TAG
	STATIC=naiveproxy-${TAG}-openwrt-${ARCH}-static.tar.xz
	PLAIN=naiveproxy-${TAG}-openwrt-${ARCH}.tar.xz
	URL=""
	for f in "$STATIC" "$PLAIN"; do
		if curl -fsSIL --max-time 15 "$BASE/$f" >/dev/null 2>&1; then
			URL=$BASE/$f
			break
		fi
	done
	[ -n "$URL" ] || err "release $TAG has no build for $ARCH (neither static nor regular). See https://github.com/$REPO/releases"
	echo "Downloading $URL"
fi

ARCHFILE=$TMP/naive.tar.xz
curl -fL --max-time 180 --retry 2 -o "$ARCHFILE" "$URL" || err "could not download the archive"
[ -s "$ARCHFILE" ] || err "the downloaded file is empty"

unxz_c "$ARCHFILE" | tar -x -C "$TMP" || err "could not unpack the archive"
BIN=$(find "$TMP" -type f -name naive | head -1)
[ -n "$BIN" ] || err "the archive has no naive file"
[ -s "$BIN" ] || err "the naive file is empty"

# Only install the binary. Never touch /etc/naive/config.json
# (the upstream tarball ships a sample config.json).
cp "$BIN" "$TMP/naive.bin"
chmod 755 "$TMP/naive.bin"
mv "$TMP/naive.bin" "$DEST"
echo "Installed $DEST ($(wc -c < "$DEST" | tr -d ' ') bytes)"
"$DEST" --version 2>/dev/null || true
echo "Done. Next, paste a naive+https:// link on the panel page and press «Connect Naive»."
