#!/bin/sh
# install-client.sh start <xray|hy2|naive|wg>   start an install in the background
#                   run   <xray|hy2|naive|wg>   do the install in the foreground (used by start)
#                   status [<xray|hy2|naive|wg>] print JSON: installed, version and install progress
#
# Button-driven installer for the four VPN clients. Each client is the official build
# from its own developer and stays a separate program with its own service:
#   xray   XTLS/Xray-core release zip -> /usr/bin/xray + geoip.dat, geosite.dat in /usr/share/xray
#          (the files from the same release; checked against the published .dgst, SHA2-256)
#   hy2    apernet/hysteria release binary -> /usr/bin/hysteria (checked against hashes.txt)
#   naive  klzgrad/naiveproxy release via install-naive.sh -> /usr/bin/naive (GitHub asset digest)
#          AND AdguardTeam/dnsproxy release -> /usr/bin/dnsproxy (the DNS helper of the Naive service,
#          started by naive-client; checked against the digest GitHub publishes for the asset or
#          checksums.txt). One progress bar: naive 0-70%, dnsproxy 70-100%. Both binaries are
#          replaced together after both downloads are verified; Naive counts as installed only
#          when both are present.
#   wg     opkg: kmod-wireguard, wireguard-tools, ip-full
# Progress goes to /tmp/aurora-install-<proto>.json:
#   {"state":"running|done|error","percent":0-100,"stage":"...","error":"...","version":"..."}
# Only one install runs at a time. A running service is touched only when its own binary is
# replaced (then that one service is restarted, and the old binary is put back on failure).
# Never run at package install time. Never changes a protocol setting or config.
set -u
CMD=${1:-}; P=${2:-}
HERE=$(dirname "$0")
VSH=${VLESS_AU_VLESS_SH:-/etc/panel/vpn.sh}
XRAY_BIN=${VLESS_XRAY_BIN:-/usr/bin/xray}
HYSTERIA_BIN=${VLESS_HYSTERIA_BIN:-/usr/bin/hysteria}
NAIVE_BIN=${VLESS_NAIVE_BIN:-/usr/bin/naive}
# naive-client starts the DNS helper as `command -v dnsproxy`; keep that same binary when one exists
DNSPROXY_BIN=${VLESS_DNSPROXY_BIN:-$(command -v dnsproxy 2>/dev/null || echo /usr/bin/dnsproxy)}
WG_BIN=${VLESS_WG_BIN:-/usr/bin/wg}
XRAY_ASSET=${VLESS_XRAY_ASSET:-/usr/share/xray}
GH=${AURORA_GH_API:-https://api.github.com}
DL=${AURORA_GH_DL:-https://github.com}
SD=${AURORA_INSTALL_DIR:-/tmp}
LOCK=$SD/aurora-install.lock
SF=$SD/aurora-install-$P.json
LOG=$SD/aurora-install-$P.log
# shellcheck disable=SC1091
. "$HERE/install-lib.sh"

usage() { echo "usage: install-client.sh start|run <xray|hy2|naive|wg> | status [xray|hy2|naive|wg]"; exit 1; }
dnsproxy_version() {
	"$DNSPROXY_BIN" --version 2>/dev/null | grep -o 'v\{0,1\}[0-9][0-9]*\.[0-9][0-9.]*[0-9a-z-]*' | head -1 | sed 's/^v//'
}
valid() { case "$1" in xray|hy2|naive|wg) return 0 ;; esac; return 1; }

# ---------- what is installed ----------
is_installed() {
	case "$1" in
		xray) [ -x "$XRAY_BIN" ] ;;
		hy2) [ -x "$HYSTERIA_BIN" ] ;;
		naive) [ -x "$NAIVE_BIN" ] && [ -x "$DNSPROXY_BIN" ] ;;
		wg) [ -x "$WG_BIN" ] && { [ -d "${VLESS_WG_SYSMOD:-/sys/module/wireguard}" ] || ls "${VLESS_WG_KO:-/lib/modules/$(uname -r)}"/wireguard.ko >/dev/null 2>&1; } ;;
	esac
}
version_of() {
	case "$1" in
		xray) "$XRAY_BIN" version 2>/dev/null | sed -n '1s/^Xray \([^ ]*\).*/\1/p' ;;
		hy2) "$HYSTERIA_BIN" version 2>/dev/null | sed -n 's/^Version:[[:space:]]*v\{0,1\}\([^ ]*\).*/\1/p' | head -1 ;;
		naive) "$NAIVE_BIN" --version 2>/dev/null | head -1 | sed 's/^naive[[:space:]]*//' ;;
		wg) _v=$(opkg list-installed wireguard-tools 2>/dev/null | awk '{print $3}')
			[ -n "$_v" ] || _v=$("$WG_BIN" --version 2>/dev/null | sed -n '1s/^wireguard-tools v\{0,1\}\([^ ]*\).*/\1/p')
			echo "$_v" ;;
	esac
}

# ---------- state file ----------
LASTPCT=0
state() { # state percent stage error version
	jq -nc --arg s "$1" --argjson p "$2" --arg st "$3" --arg e "$4" --arg v "$5" --argjson t "$(date +%s)" \
		'{state:$s,percent:$p,stage:$st,error:$e,version:$v,updated:$t}' > "$SF.tmp.$$" 2>/dev/null && mv "$SF.tmp.$$" "$SF"
}
ai_on_progress() { # called by the lib and by progress(); never goes backwards
	[ "$1" -ge "$LASTPCT" ] || return 0
	[ "$1" -le 99 ] || return 0
	LASTPCT=$1
	state running "$1" "$2" "" ""
}
progress() { ai_prog "$1" "$2"; }
FINISHED=0
fail() { # short reason
	FINISHED=1
	_m=$(printf '%s' "$1" | tr '\n\r\t' '   ' | cut -c1-200)
	state error "$LASTPCT" "${STAGE:-failed}" "$_m" ""
	echo "ERROR: $_m" >&2
	exit 1
}
STAGE=""

# ---------- shared steps ----------
need_tool() { # command opkg-package
	command -v "$1" >/dev/null 2>&1 && return 0
	command -v opkg >/dev/null 2>&1 || fail "$1 is missing and opkg is not available"
	opkg update >/dev/null 2>&1
	opkg install "$2" >"$TMP/opkg-tool.log" 2>&1 || fail "$1 is missing and could not be installed: $(tail -1 "$TMP/opkg-tool.log")"
	command -v "$1" >/dev/null 2>&1 || fail "$1 is still missing after installing $2"
}
space() { # path kb
	_m=$(ai_need_space "$1" "$2") || fail "$_m"
}
get() { # url out lo hi what
	_mx=${AURORA_DL_MAX:-300}; [ -n "$3" ] || _mx=40
	ai_fetch "$1" "$2" "$3" "$4" "$_mx" || fail "could not download $5 (GitHub is not reachable directly or through the active tunnel)"
}
latest_tag() { # repo -> sets TAG
	get "$GH/repos/$1/releases/latest" "$TMP/release.json" "" "" "the release info"
	TAG=$(jq -r '.tag_name // empty' "$TMP/release.json" 2>/dev/null)
	[ -n "$TAG" ] || fail "could not read the latest release of $1"
}
sha_ok() { # file expected
	[ -n "$2" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]
}
arch_go() {
	case "$(uname -m)" in
		aarch64|arm64) echo arm64 ;;
		x86_64|amd64) echo amd64 ;;
		armv7*|armv6*|arm) echo arm ;;
		*) return 1 ;;
	esac
}
# dnsproxy release arch (AdguardTeam/dnsproxy assets: linux-<arch>): from the OpenWrt arch name, else uname
arch_dp() {
	_da=$(sed -n "s/^DISTRIB_ARCH=['\"]\{0,1\}\([^'\"]*\).*/\1/p" "${AURORA_OPENWRT_RELEASE:-/etc/openwrt_release}" 2>/dev/null | head -1)
	case "$_da" in
		aarch64*) echo arm64; return 0 ;;
		x86_64) echo amd64; return 0 ;;
		i386*|x86) echo 386; return 0 ;;
		mips64el*) echo mips64le; return 0 ;;
		mips64*) echo mips64; return 0 ;;
		mipsel*) echo mipsle; return 0 ;;
		mips*) echo mips; return 0 ;;
		arm_cortex-a5*|arm_cortex-a7*|arm_cortex-a8*|arm_cortex-a9*|arm_cortex-a1[0-9]*|arm_neoverse*) echo arm7; return 0 ;;
		arm_mpcore*|arm_1176*|arm_arm1176*) echo arm6; return 0 ;;
		arm_*) echo arm5; return 0 ;;
	esac
	case "$(uname -m)" in
		aarch64|arm64) echo arm64 ;;
		x86_64|amd64) echo amd64 ;;
		i386|i486|i586|i686) echo 386 ;;
		armv7*) echo arm7 ;;
		armv6*) echo arm6 ;;
		arm*) echo arm5 ;;
		mips64) echo mips64 ;;
		mips) echo mips ;;
		*) return 1 ;;
	esac
}
put_try() { # like put, but returns 1 instead of stopping the install
	_n="$2.new.$$"
	if ! cp "$1" "$_n" 2>/dev/null; then rm -f "$_n"; return 1; fi
	chmod "$3" "$_n"
	mv "$_n" "$2" || { rm -f "$_n"; return 1; }
}
put() { # src dest : copy next to dest, then atomic rename (same filesystem)
	_n="$2.new.$$"
	if ! cp "$1" "$_n" 2>/dev/null; then rm -f "$_n"; fail "could not write $2 (no space left?)"; fi
	chmod "$3" "$_n"
	mv "$_n" "$2" || { rm -f "$_n"; fail "could not replace $2"; }
}
# $1 service name for vpn.sh restart-svc, $2 process name(s) of that service (any one running
# means the service is running), then dest files to restore on failure
restart_or_rollback() {
	svc=$1; procs=$2; shift 2
	_up=0
	for _pr in $procs; do pidof "$_pr" >/dev/null 2>&1 && _up=1; done
	[ "$_up" = 1 ] || return 0
	STAGE=restarting; progress 94 restarting
	if ! "$VSH" restart-svc "$svc" >/dev/null 2>&1; then
		for f in "$@"; do [ -e "$TMP/old/$(basename "$f")" ] && cp -p "$TMP/old/$(basename "$f")" "$f"; done
		"$VSH" restart-svc "$svc" >/dev/null 2>&1
		fail "$svc did not start with the new version; the old one was put back"
	fi
}
keep_old() { mkdir -p "$TMP/old"; for f in "$@"; do [ -e "$f" ] && cp -p "$f" "$TMP/old/$(basename "$f")"; done; return 0; }

# ---------- installers ----------
do_xray() {
	STAGE=checking; progress 1 checking
	A=$(arch_go) || fail "unsupported CPU architecture ($(uname -m))"
	case "$A" in arm64) XA=arm64-v8a ;; amd64) XA=64 ;; arm) XA=arm32-v7a ;; esac
	need_tool curl curl; need_tool unzip unzip
	space "$TMP" 70000; space "$(dirname "$XRAY_BIN")" 50000; space "$XRAY_ASSET" 50000
	STAGE=resolving; progress 6 resolving
	latest_tag XTLS/Xray-core; tag=$TAG
	f=Xray-linux-$XA.zip
	STAGE=downloading; progress 10 downloading
	get "$DL/XTLS/Xray-core/releases/download/$tag/$f" "$TMP/x.zip" 10 62 "Xray"
	STAGE=verifying; progress 64 verifying
	get "$DL/XTLS/Xray-core/releases/download/$tag/$f.dgst" "$TMP/x.dgst" "" "" "the Xray checksum file"
	sha_ok "$TMP/x.zip" "$(sed -n 's/^SHA2-256= *//p' "$TMP/x.dgst" | head -1)" || fail "checksum mismatch: the Xray download is damaged or was changed"
	STAGE=unpacking; progress 70 unpacking
	unzip -o -q "$TMP/x.zip" xray geoip.dat geosite.dat -d "$TMP/x" || fail "could not unpack the Xray archive"
	[ -s "$TMP/x/xray" ] && [ -s "$TMP/x/geoip.dat" ] && [ -s "$TMP/x/geosite.dat" ] || fail "the Xray archive has no xray, geoip.dat or geosite.dat"
	chmod 755 "$TMP/x/xray"
	"$TMP/x/xray" version >/dev/null 2>&1 || fail "the downloaded Xray does not run on this router"
	STAGE=installing; progress 80 installing
	mkdir -p "$XRAY_ASSET"
	keep_old "$XRAY_BIN" "$XRAY_ASSET/geoip.dat" "$XRAY_ASSET/geosite.dat"
	put "$TMP/x/geoip.dat" "$XRAY_ASSET/geoip.dat" 644; progress 84 installing
	put "$TMP/x/geosite.dat" "$XRAY_ASSET/geosite.dat" 644; progress 88 installing
	put "$TMP/x/xray" "$XRAY_BIN" 755; progress 92 installing
	restart_or_rollback xray xray "$XRAY_BIN" "$XRAY_ASSET/geoip.dat" "$XRAY_ASSET/geosite.dat"
}

do_hy2() {
	STAGE=checking; progress 1 checking
	A=$(arch_go) || fail "unsupported CPU architecture ($(uname -m))"
	need_tool curl curl
	space "$TMP" 30000; space "$(dirname "$HYSTERIA_BIN")" 30000
	STAGE=resolving; progress 6 resolving
	latest_tag apernet/hysteria; tag=$TAG
	f=hysteria-linux-$A
	STAGE=downloading; progress 10 downloading
	get "$DL/apernet/hysteria/releases/download/$tag/$f" "$TMP/h" 10 75 "Hysteria 2"
	STAGE=verifying; progress 78 verifying
	get "$DL/apernet/hysteria/releases/download/$tag/hashes.txt" "$TMP/hashes.txt" "" "" "the Hysteria checksum file"
	sha_ok "$TMP/h" "$(awk -v f="build/$f" '$2==f{print $1}' "$TMP/hashes.txt")" || fail "checksum mismatch: the Hysteria download is damaged or was changed"
	chmod 755 "$TMP/h"
	"$TMP/h" version >/dev/null 2>&1 || fail "the downloaded Hysteria does not run on this router"
	STAGE=installing; progress 85 installing
	keep_old "$HYSTERIA_BIN"
	put "$TMP/h" "$HYSTERIA_BIN" 755; progress 90 installing
	restart_or_rollback hysteria hysteria "$HYSTERIA_BIN"
}

do_naive() {
	STAGE=checking; progress 1 checking
	need_tool curl curl
	command -v xz >/dev/null 2>&1 || command -v unxz >/dev/null 2>&1 || need_tool xz xz
	DA=$(arch_dp) || fail "unsupported CPU architecture ($(uname -m)) for dnsproxy"
	space "$(dirname "$NAIVE_BIN")" 30000; space "$(dirname "$DNSPROXY_BIN")" 25000
	# Part 1 (0-70%): Naive is unpacked into the temporary directory; nothing on the router changes yet.
	: > "$TMP/naive.out"
	# shellcheck disable=SC2086
	VLESS_NAIVE_BIN=$TMP/naive.new AURORA_PROGRESS=1 sh "$HERE/install-naive.sh" --force 2>&1 | while IFS= read -r l; do
		case "$l" in
			"@PROGRESS "*) set -- $l; [ "$2" -le 86 ] || set -- "$1" 86 "$3"; ai_on_progress $(($2 * 70 / 86)) "$3" ;;
			"@ERROR "*) printf '%s\n' "${l#@ERROR }" > "$TMP/naive.err" ;;
			"@DONE") : > "$TMP/naive.done" ;;
			*) printf '%s\n' "$l" >> "$TMP/naive.out" ;;
		esac
	done
	[ -e "$TMP/naive.done" ] && [ -s "$TMP/naive.new" ] || fail "$(cat "$TMP/naive.err" 2>/dev/null || tail -1 "$TMP/naive.out")"
	# Part 2 (70-100%): dnsproxy, the DNS helper that naive-client starts next to Naive.
	LASTPCT=70
	space "$TMP" 30000
	STAGE=resolving; progress 72 resolving
	latest_tag AdguardTeam/dnsproxy; dtag=$TAG
	df=dnsproxy-linux-$DA-$dtag.tar.gz
	dsha=$(jq -r --arg n "$df" '.assets // [] | map(select(.name==$n)) | .[0].digest // empty' "$TMP/release.json" 2>/dev/null | sed -n 's/^sha256://p')
	STAGE=downloading; progress 74 downloading
	get "$DL/AdguardTeam/dnsproxy/releases/download/$dtag/$df" "$TMP/dp.tgz" 74 90 "dnsproxy"
	STAGE=verifying; progress 91 verifying
	if [ -z "$dsha" ]; then
		ai_fetch "$DL/AdguardTeam/dnsproxy/releases/download/$dtag/checksums.txt" "$TMP/dp.sums" "" "" 40 || : > "$TMP/dp.sums"
		dsha=$(awk -v f="$df" '$2==f || $2=="*" f {print $1}' "$TMP/dp.sums" | head -1)
	fi
	[ -n "$dsha" ] || fail "no checksum is published for the dnsproxy download"
	sha_ok "$TMP/dp.tgz" "$dsha" || fail "checksum mismatch: the dnsproxy download is damaged or was changed"
	STAGE=unpacking; progress 93 unpacking
	mkdir -p "$TMP/dp"
	tar -xzf "$TMP/dp.tgz" -C "$TMP/dp" || fail "could not unpack the dnsproxy archive"
	DPB=$(find "$TMP/dp" -type f -name dnsproxy | head -1)
	[ -n "$DPB" ] && [ -s "$DPB" ] || fail "the dnsproxy archive has no dnsproxy file"
	chmod 755 "$DPB"
	"$DPB" --version >/dev/null 2>&1 || fail "the downloaded dnsproxy does not run on this router"
	# Both verified: replace both together, so Naive is never left half installed.
	STAGE=installing; progress 95 installing
	keep_old "$NAIVE_BIN" "$DNSPROXY_BIN"
	if ! { put_try "$TMP/naive.new" "$NAIVE_BIN" 755 && put_try "$DPB" "$DNSPROXY_BIN" 755; }; then
		for f in "$NAIVE_BIN" "$DNSPROXY_BIN"; do
			if [ -e "$TMP/old/$(basename "$f")" ]; then cp -p "$TMP/old/$(basename "$f")" "$f"; else rm -f "$f"; fi
		done
		fail "could not write the Naive files (no space left?); the old ones were put back"
	fi
	progress 97 installing
	restart_or_rollback naive "naive dnsproxy" "$NAIVE_BIN" "$DNSPROXY_BIN"
}

do_wg() {
	STAGE=checking; progress 1 checking
	command -v opkg >/dev/null 2>&1 || fail "opkg is not available on this system"
	space "$TMP" 8000; space /usr/lib 6000
	UPG=0; is_installed wg && UPG=1
	STAGE=pkg-update; progress 5 pkg-update
	opkg update >"$TMP/opkg.log" 2>&1 || fail "opkg update failed: $(tail -1 "$TMP/opkg.log")"
	STAGE=pkg-kernel; progress 30 pkg-kernel
	opkg install kmod-wireguard >"$TMP/opkg.log" 2>&1 || fail "could not install kmod-wireguard: $(tail -1 "$TMP/opkg.log")"
	[ "$UPG" = 1 ] && { opkg upgrade kmod-wireguard >"$TMP/opkg.log" 2>&1 || fail "could not upgrade kmod-wireguard: $(tail -1 "$TMP/opkg.log")"; }
	STAGE=pkg-tools; progress 55 pkg-tools
	opkg install wireguard-tools >"$TMP/opkg.log" 2>&1 || fail "could not install wireguard-tools: $(tail -1 "$TMP/opkg.log")"
	[ "$UPG" = 1 ] && { opkg upgrade wireguard-tools >"$TMP/opkg.log" 2>&1 || fail "could not upgrade wireguard-tools: $(tail -1 "$TMP/opkg.log")"; }
	STAGE=pkg-ip; progress 75 pkg-ip
	opkg install ip-full >"$TMP/opkg.log" 2>&1 || fail "could not install ip-full: $(tail -1 "$TMP/opkg.log")"
	STAGE=verifying; progress 92 verifying
	is_installed wg || fail "the packages are installed but the WireGuard kernel module is not available (a reboot may be needed)"
}

# ---------- commands ----------
lock_alive() {
	_pid=$(cat "$LOCK/pid" 2>/dev/null)
	if [ -n "$_pid" ]; then kill -0 "$_pid" 2>/dev/null; return $?; fi
	_ts=$(cat "$LOCK/ts" 2>/dev/null || echo 0)
	[ $(( $(date +%s) - _ts )) -lt 20 ]
}

status_one() { # proto
	_p=$1; _f=$SD/aurora-install-$_p.json
	_inst=false; _ver=""
	if is_installed "$_p"; then _inst=true; fi
	_st='{}'
	[ -s "$_f" ] && _st=$(cat "$_f")
	_run=$(printf '%s' "$_st" | jq -r '.state // ""' 2>/dev/null)
	if [ "$_run" = running ]; then
		if ! { [ "$(cat "$LOCK/proto" 2>/dev/null)" = "$_p" ] && lock_alive; }; then
			_st='{"state":"error","percent":0,"stage":"failed","error":"the installation was interrupted"}'
		fi
	fi
	[ "$_run" = running ] || { [ "$_inst" = true ] && _ver=$(version_of "$_p"); }
	# Naive is two programs: report the dnsproxy version and what is missing
	_dv=""; _miss=""
	if [ "$_p" = naive ]; then
		[ -x "$DNSPROXY_BIN" ] && _dv=$(dnsproxy_version)
		[ -x "$NAIVE_BIN" ] || _miss="naive"
		[ -x "$DNSPROXY_BIN" ] || _miss="${_miss:+$_miss, }dnsproxy"
		[ "$_inst" = true ] && _miss=""
	fi
	printf '%s' "$_st" | jq -c --arg p "$_p" --argjson i "$_inst" --arg v "$_ver" --arg dv "$_dv" --arg m "$_miss" \
		'{proto:$p,installed:$i,version:(if $v!="" then $v else (.version // "") end),state:(.state // "idle"),percent:(.percent // 0),stage:(.stage // ""),error:(.error // "")}
		 + (if $p=="naive" then {dnsproxy_version:(if $dv!="" then $dv else (.dnsproxy_version // "") end),missing:$m} else {} end)'
}

case "$CMD" in
	status)
		if [ -n "$P" ]; then valid "$P" || usage; SF=$SD/aurora-install-$P.json; status_one "$P"; exit 0; fi
		for _p in xray hy2 naive wg; do status_one "$_p"; done | jq -sc 'map({key:.proto,value:.})|from_entries'
		exit 0 ;;
	start)
		valid "$P" || usage
		command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required"; exit 1; }
		if ! mkdir "$LOCK" 2>/dev/null; then
			if lock_alive; then echo "ERROR: another installation is running ($(cat "$LOCK/proto" 2>/dev/null))"; exit 1; fi
			rm -rf "$LOCK"
			mkdir "$LOCK" 2>/dev/null || { echo "ERROR: could not start the installation"; exit 1; }
		fi
		date +%s > "$LOCK/ts"; echo "$P" > "$LOCK/proto"
		state running 0 queued "" ""
		if command -v setsid >/dev/null 2>&1; then
			setsid sh "$0" run "$P" >"$LOG" 2>&1 </dev/null &
		else
			sh "$0" run "$P" >"$LOG" 2>&1 </dev/null &
		fi
		echo $! > "$LOCK/pid"
		echo "OK: installation of $P started"
		exit 0 ;;
	run)
		valid "$P" || usage
		TMP=$(mktemp -d "$SD/aurora-install.XXXXXX") || { echo "ERROR: no temporary directory" >&2; exit 1; }
		# shellcheck disable=SC2329
		cleanup() {
			if [ "$FINISHED" != 1 ]; then state error "$LASTPCT" "${STAGE:-failed}" "the installation was interrupted" ""; fi
			rm -rf "$TMP" "$LOCK"
		}
		trap cleanup EXIT
		trap 'exit 1' INT TERM HUP
		state running 0 queued "" ""
		case "$P" in
			xray) do_xray ;;
			hy2) do_hy2 ;;
			naive) do_naive ;;
			wg) do_wg ;;
		esac
		VER=$(version_of "$P")
		FINISHED=1
		state "done" 100 "done" "" "$VER"
		echo "OK: $P installed ${VER:-}"
		exit 0 ;;
	*) usage ;;
esac
