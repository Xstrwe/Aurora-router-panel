#!/bin/sh
# Shared helpers for install-client.sh and install-naive.sh (sourced, never run).
#
#   ai_prog PCT STAGE     report progress (prints "@PROGRESS PCT STAGE" when AURORA_PROGRESS=1,
#                         and calls ai_on_progress if the caller defined it)
#   ai_free_kb PATH       free space in KiB on the filesystem that holds PATH
#   ai_need_space PATH KB fail with a message unless PATH has KB KiB free
#   ai_fetch URL OUT [LO HI [MAXSEC]]
#                         download URL to OUT. Tries a direct connection first, then the
#                         local SOCKS entry of the ACTIVE protocol (when it is listening),
#                         for the case when GitHub is blocked on the direct path.
#                         With LO/HI the download percent is mapped onto LO..HI.
# Nothing here changes any protocol, service or setting.

AI_PDIR=${VLESS_PANEL_DIR:-/etc/xray}

ai_prog() {
	[ "${AURORA_PROGRESS:-0}" = 1 ] && echo "@PROGRESS $1 $2"
	if command -v ai_on_progress >/dev/null 2>&1; then ai_on_progress "$1" "$2"; fi
	return 0
}

ai_free_kb() {
	_p=$1
	while [ ! -e "$_p" ] && [ "$_p" != / ]; do _p=$(dirname "$_p"); done
	df -k "$_p" 2>/dev/null | awk 'END{print $4+0}'
}

ai_need_space() {
	_have=$(ai_free_kb "$1")
	if [ "$_have" -lt "$2" ]; then
		echo "not enough free space on $1: $((_have / 1024)) MB free, $((($2 + 1023) / 1024)) MB needed"
		return 1
	fi
	return 0
}

# Local SOCKS entries of the active protocol only (ports as in vpn.sh nat_probe_once).
ai_socks_entries() {
	case "$(cat "$AI_PDIR/proto" 2>/dev/null)" in
		hy2) _port=10818 ;;
		naive) _port=10828 ;;
		wg) return 0 ;;
		*) _port=10808 ;;
	esac
	if [ -n "${AURORA_SOCKS_FORCE:-}" ]; then echo "$AURORA_SOCKS_FORCE"; return 0; fi
	netstat -lnt 2>/dev/null | grep -q "[:.]$_port " && echo "127.0.0.1:$_port"
	return 0
}

ai_fetch() { # url out [lo hi [maxsec]]
	_url=$1; _out=$2; _lo=${3:-}; _hi=${4:-}; _max=${5:-300}
	_plog=${AI_TMPDIR:-/tmp}/aurora-curl.$$.log
	for _via in "" $(ai_socks_entries); do
		rm -f "$_out"; : > "$_plog"
		if [ -z "$_via" ]; then
			curl -fL --connect-timeout 15 --max-time "$_max" --progress-bar -o "$_out" "$_url" 2>"$_plog" &
		else
			curl -fL --connect-timeout 15 --max-time "$_max" --progress-bar --socks5-hostname "$_via" -o "$_out" "$_url" 2>"$_plog" &
		fi
		_cp=$!
		while kill -0 "$_cp" 2>/dev/null; do
			if [ -n "$_lo" ]; then
				_pc=$(tr '\r' '\n' < "$_plog" | sed 's/^/ /' | sed -n 's/.*[^0-9.]\([0-9]\{1,3\}\)\.[0-9]%.*/\1/p' | tail -1)
				if [ -n "$_pc" ]; then ai_prog $((_lo + (_hi - _lo) * _pc / 100)) downloading; fi
			fi
			sleep "${AURORA_POLL:-1}"
		done
		if wait "$_cp" && [ -s "$_out" ]; then rm -f "$_plog"; return 0; fi
	done
	rm -f "$_plog" "$_out"
	return 1
}
