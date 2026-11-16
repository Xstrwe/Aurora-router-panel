#!/bin/sh
# client-update.sh <xray|hysteria|naive|wireguard> <check|install>
# Updates ONE VPN client from its own upstream and restarts only that client's service
# (and only if it is running now). Nothing else is touched: no other client, no config.
#   xray      XTLS/Xray-core release zip, checked against the published .dgst (SHA2-256)
#   hysteria  apernet/hysteria release binary, checked against the published hashes.txt
#   naive     klzgrad/naiveproxy release (install-naive.sh)
#   wireguard the OpenWrt/GL.iNet feed: opkg upgrade kmod-wireguard wireguard-tools
# The previous binary is kept as <binary>.bak and put back if the new one does not start.
set -u
WHO=${1:-}; ACT=${2:-check}
VSH=${VLESS_AU_VLESS_SH:-/etc/xray/vless.sh}
XRAY_BIN=${VLESS_XRAY_BIN:-/usr/bin/xray}
HYSTERIA_BIN=${VLESS_HYSTERIA_BIN:-/usr/bin/hysteria}
GH=${AURORA_GH_API:-https://api.github.com}
DL=${AURORA_GH_DL:-https://github.com}
err() { echo "ERROR: $*"; exit 1; }
case "$ACT" in check|install) ;; *) err "usage: client-update.sh xray|hysteria|naive|wireguard check|install";; esac
arch() {
	case "$(uname -m)" in
		aarch64|arm64) echo arm64;;
		x86_64|amd64) echo amd64;;
		armv7*|armv6*|arm) echo arm;;
		*) return 1;;
	esac
}
latest_tag() { # repo
	curl -fsSL --max-time 25 "$GH/repos/$1/releases/latest" | jq -r '.tag_name // empty'
}
up() { pidof "$1" >/dev/null 2>&1; }
swap_in() { # newfile dest service process versioncmd...
	new=$1; dest=$2; svc=$3; proc=$4; shift 4
	chmod 755 "$new"
	"$new" "$@" >/dev/null 2>&1 || err "the downloaded binary does not run on this router"
	[ -e "$dest" ] && cp -a "$dest" "$dest.bak"
	mv "$new" "$dest"
	if up "$proc"; then
		if ! "$VSH" restart-svc "$svc" >/dev/null 2>&1; then
			[ -e "$dest.bak" ] && mv "$dest.bak" "$dest" && "$VSH" restart-svc "$svc" >/dev/null 2>&1
			err "$svc did not start with the new binary; the old one was put back"
		fi
	fi
	echo "OK: $dest updated ($("$dest" "$@" 2>/dev/null | head -1))"
}
sha_ok() { # file expected
	[ -n "$2" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]
}
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
case "$WHO" in
	xray)
		A=$(arch) || err "unsupported architecture"
		[ "$A" = arm64 ] && XA=arm64-v8a; [ "$A" = amd64 ] && XA=64; [ "$A" = arm ] && XA=arm32-v7a
		tag=$(latest_tag XTLS/Xray-core); [ -n "$tag" ] || err "could not read the latest Xray-core release"
		cur=$("$XRAY_BIN" version 2>/dev/null | sed -n '1s/^Xray \([^ ]*\).*/\1/p')
		echo "xray installed=${cur:-none} latest=${tag#v} source=XTLS/Xray-core"
		[ "$ACT" = install ] || exit 0
		f=Xray-linux-$XA.zip
		curl -fsSL --max-time 180 -o "$TMPD/x.zip" "$DL/XTLS/Xray-core/releases/download/$tag/$f" || err "download failed"
		curl -fsSL --max-time 25 -o "$TMPD/x.dgst" "$DL/XTLS/Xray-core/releases/download/$tag/$f.dgst" || err "no checksum file"
		sha_ok "$TMPD/x.zip" "$(sed -n 's/^SHA2-256= *//p' "$TMPD/x.dgst" | head -1)" || err "checksum mismatch"
		unzip -o -q "$TMPD/x.zip" xray -d "$TMPD" || err "could not unpack"
		swap_in "$TMPD/xray" "$XRAY_BIN" xray xray version;;
	hysteria)
		A=$(arch) || err "unsupported architecture"
		tag=$(latest_tag apernet/hysteria); [ -n "$tag" ] || err "could not read the latest hysteria release"
		cur=$("$HYSTERIA_BIN" version 2>/dev/null | sed -n 's/^Version:[[:space:]]*v\{0,1\}\([^ ]*\).*/\1/p' | head -1)
		echo "hysteria installed=${cur:-none} latest=${tag#app/v} source=apernet/hysteria"
		[ "$ACT" = install ] || exit 0
		f=hysteria-linux-$A
		curl -fsSL --max-time 180 -o "$TMPD/h" "$DL/apernet/hysteria/releases/download/$tag/$f" || err "download failed"
		curl -fsSL --max-time 25 -o "$TMPD/hashes.txt" "$DL/apernet/hysteria/releases/download/$tag/hashes.txt" || err "no checksum file"
		sha_ok "$TMPD/h" "$(awk -v f="build/$f" '$2==f{print $1}' "$TMPD/hashes.txt")" || err "checksum mismatch"
		swap_in "$TMPD/h" "$HYSTERIA_BIN" hysteria hysteria version;;
	naive)
		tag=$(latest_tag klzgrad/naiveproxy); [ -n "$tag" ] || err "could not read the latest Naive release"
		cur=$(${VLESS_NAIVE_BIN:-/usr/bin/naive} --version 2>/dev/null | head -1)
		echo "naive installed=${cur:-none} latest=${tag#v} source=klzgrad/naiveproxy"
		[ "$ACT" = install ] || exit 0
		sh "$(dirname "$0")/install-naive.sh" --force || err "Naive install failed"
		up naive && "$VSH" restart-svc naive >/dev/null 2>&1
		echo "OK: naive updated";;
	wireguard)
		cur=$(opkg list-installed wireguard-tools 2>/dev/null | awk '{print $3}')
		echo "wireguard installed=${cur:-none} source=opkg feed"
		[ "$ACT" = install ] || exit 0
		opkg update >/dev/null 2>&1 || err "opkg update failed"
		opkg upgrade wireguard-tools kmod-wireguard >/dev/null 2>&1 || err "opkg upgrade failed"
		echo "OK: wireguard packages upgraded (the running interface keeps the old kernel module until reboot)";;
	*) err "usage: client-update.sh xray|hysteria|naive|wireguard check|install";;
esac
