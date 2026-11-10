#!/bin/sh
# Hourly cron runner: for each enabled proto, run vless.sh update
# when its interval has elapsed. Idempotent; skips a second overlap.
set -u

D=${VLESS_PANEL_DIR:-/etc/xray}
HYD=${VLESS_HYSTERIA_DIR:-/etc/hysteria}
NAD=${VLESS_NAIVE_DIR:-/etc/naive}
LIB=${VLESS_AU_LIB:-/usr/libexec/vless-panel/autoupdate-lib.sh}
# shellcheck disable=SC1090
. "$LIB"

SH=${VLESS_SH:-/etc/xray/vless.sh}
LOCK=${VLESS_AU_LOCK:-/var/run/vless-panel-autoupdate.lock}

log() { logger -t vless-autoupdate "$*" 2>/dev/null || echo "autoupdate: $*" >&2; }

if [ -f "$LOCK" ]; then
	old=$(tr -d ' \n' < "$LOCK")
	if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
		log "already running (pid $old)"
		exit 0
	fi
fi
printf '%s\n' "$$" > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

now=$(date +%s)
for p in vless hy2 naive wg; do
	au_load "$p" || continue
	[ "$AU_ENABLED" = 1 ] || continue
	au_due "$p" "$now" || continue
	if "$SH" update "$p"; then
		au_stamp "$p" "$now"
		log "$p: ok"
	else
		log "$p: failed"
	fi
done
exit 0
