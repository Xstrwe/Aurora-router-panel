# Shared autoupdate helpers for vless.sh and autoupdate-run.sh.
# Safe to source: no work at load time, no eval of user files.
# Override paths with VLESS_PANEL_DIR, VLESS_HYSTERIA_DIR, VLESS_NAIVE_DIR,
# VLESS_AU_SERVER, VLESS_AU_CRON, VLESS_SH.

[ -n "${D:-}" ] || D=${VLESS_PANEL_DIR:-/etc/xray}
[ -n "${HYD:-}" ] || HYD=${VLESS_HYSTERIA_DIR:-/etc/hysteria}
[ -n "${NAD:-}" ] || NAD=${VLESS_NAIVE_DIR:-/etc/naive}
AU_DIR=$D/autoupdate
AU_SERVER=${VLESS_AU_SERVER:-/usr/libexec/vless-panel/autoupdate-server}
AU_CRON=${VLESS_AU_CRON:-/etc/crontabs/root}
AU_CRON_MARK='vless-router-panel-autoupdate'
AU_RUN=${VLESS_AU_RUN:-/usr/libexec/vless-panel/autoupdate-run.sh}
AU_SH=${VLESS_SH:-/etc/xray/vless.sh}

au_ok_proto() { case "$1" in vless|hy2|naive|wg) return 0;; *) return 1;; esac; }

# Read /etc/xray/autoupdate/<proto>.conf without sourcing it.
# Sets AU_ENABLED AU_SOURCE AU_URL AU_INTERVAL.
au_load() {
	AU_ENABLED=0
	AU_SOURCE=url
	AU_URL=
	AU_INTERVAL=24h
	[ -n "$1" ] && au_ok_proto "$1" || return 1
	[ -f "$AU_DIR/$1.conf" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			enabled=0|enabled=1) AU_ENABLED=${line#enabled=} ;;
			source=server|source=url) AU_SOURCE=${line#source=} ;;
			interval=1h|interval=6h|interval=24h) AU_INTERVAL=${line#interval=} ;;
			url=*) AU_URL=${line#url=} ;;
		esac
	done < "$AU_DIR/$1.conf"
	return 0
}

au_save_conf() {
	# proto enabled source url interval
	au_ok_proto "$1" || return 1
	case "$2" in 0|1) ;; *) return 1;; esac
	case "$3" in server|url) ;; *) return 1;; esac
	case "$5" in 1h|6h|24h) ;; *) return 1;; esac
	mkdir -p "$AU_DIR"
	umask 077
	{
		printf 'enabled=%s\n' "$2"
		printf 'source=%s\n' "$3"
		printf 'url=%s\n' "$4"
		printf 'interval=%s\n' "$5"
	} > "$AU_DIR/$1.conf"
	chmod 600 "$AU_DIR/$1.conf" 2>/dev/null || true
}

# First non-comment, non-empty line of the packaged default server file.
au_server_url() {
	[ -f "$AU_SERVER" ] || { echo ""; return 0; }
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			''|\#*) continue ;;
			http://*|https://*) printf '%s\n' "$line"; return 0 ;;
		esac
	done < "$AU_SERVER"
	echo ""
}

# Resolve the fetch URL for a proto (after au_load). Prints URL or nothing.
au_resolve_url() {
	if [ "$AU_SOURCE" = server ]; then
		au_server_url
	else
		printf '%s\n' "$AU_URL"
	fi
}

au_current_file() {
	case "$1" in
		vless) printf '%s\n' "$D/link.txt" ;;
		hy2) printf '%s\n' "$D/hy2.txt" ;;
		naive) printf '%s\n' "$D/naive.txt" ;;
		wg) printf '%s\n' "$D/wg.conf" ;;
		*) return 1 ;;
	esac
}

# Normalize a file for comparison. Links: strip CR/space/newlines.
# WireGuard: strip CR and trailing spaces, keep line structure.
au_norm() {
	if [ "$1" = wg ]; then
		tr -d '\r' < "$2" | sed 's/[[:space:]]*$//'
	else
		tr -d '\r\n\t ' < "$2"
	fi
}

au_same() {
	# proto file_a file_b
	[ -f "$2" ] && [ -f "$3" ] || return 1
	a=$(au_norm "$1" "$2")
	b=$(au_norm "$1" "$3")
	[ "$a" = "$b" ]
}

# Decode a possible base64 or base64url body into stdout. Empty on failure.
au_b64d() {
	t=$(tr -d ' \t\n\r' < "$1")
	[ -n "$t" ] || return 1
	printf '%s' "$t" | base64 -d 2>/dev/null && return 0
	# base64url + padding
	t=$(printf '%s' "$t" | tr -- '-_' '+/')
	case $(( ${#t} % 4 )) in
		1) return 1 ;;
		2) t=$t'==' ;;
		3) t=$t'=' ;;
	esac
	printf '%s' "$t" | base64 -d 2>/dev/null
}

# First entry of this protocol from a text blob on stdin; empty if none.
# Drops a UTF-8 BOM without sed octal (GNU sed treats \\273 as a backref).
au_first() {
	P=$1
	text=$(cat)
	bom=$(printf '\357\273\277')
	case "$text" in
		"$bom"*) text=${text#"$bom"} ;;
	esac
	text=$(printf '%s\n' "$text" | tr -d '\r')
	case "$P" in
		vless)
			printf '%s\n' "$text" | tr '\r' '\n' | sed -n 's/.*\(vless:\/\/[^[:space:]]*\).*/\1/p' | head -1
			;;
		hy2)
			printf '%s\n' "$text" | tr '\r' '\n' | sed -n -e 's/.*\(hysteria2:\/\/[^[:space:]]*\).*/\1/p' -e 's/.*\(hy2:\/\/[^[:space:]]*\).*/\1/p' | head -1
			;;
		naive)
			printf '%s\n' "$text" | tr '\r' '\n' | sed -n 's/.*\(naive+https:\/\/[^[:space:]]*\).*/\1/p' | head -1
			;;
		wg)
			printf '%s\n' "$text" | tr -d '\r' | grep -qi '\[Interface\]' || return 1
			printf '%s\n' "$text" | tr -d '\r'
			;;
		*) return 1 ;;
	esac
}

# infile proto outfile — raw link/config or base64 subscription.
au_extract() {
	IN=$1 P=$2 OUT=$3
	[ -s "$IN" ] || return 1
	tmp=$IN.plain
	tr -d '\r' < "$IN" > "$tmp"
	got=$(au_first "$P" < "$tmp")
	if [ -n "$got" ]; then
		printf '%s\n' "$got" > "$OUT"
		rm -f "$tmp"
		return 0
	fi
	if au_b64d "$tmp" > "$IN.dec" 2>/dev/null && [ -s "$IN.dec" ]; then
		got=$(au_first "$P" < "$IN.dec")
		rm -f "$IN.dec"
		if [ -n "$got" ]; then
			printf '%s\n' "$got" > "$OUT"
			rm -f "$tmp"
			return 0
		fi
	fi
	rm -f "$tmp" "$IN.dec"
	return 1
}

au_interval_sec() {
	case "$1" in
		1h) echo 3600 ;;
		6h) echo 21600 ;;
		24h) echo 86400 ;;
		*) echo 86400 ;;
	esac
}

au_stamp_file() { printf '%s\n' "$AU_DIR/$1.stamp"; }

au_due() {
	# proto now_epoch — 0 if it is time to update
	au_load "$1" || return 1
	[ "$AU_ENABLED" = 1 ] || return 1
	now=${2:-$(date +%s)}
	need=$(au_interval_sec "$AU_INTERVAL")
	sf=$(au_stamp_file "$1")
	[ -f "$sf" ] || return 0
	last=$(tr -d ' \n\r' < "$sf")
	case "$last" in
		''|*[!0-9]*) return 0 ;;
	esac
	[ $((now - last)) -ge "$need" ]
}

au_stamp() {
	mkdir -p "$AU_DIR"
	printf '%s\n' "${2:-$(date +%s)}" > "$(au_stamp_file "$1")"
}

# Backup / restore user + generated files. Naive config.json is renamed
# so it does not collide with xray's config.json.
au_backup() {
	B=$1
	mkdir -p "$B"
	for f in \
		"$D/config.json" "$D/config.prev.json" \
		"$D/link.txt" "$D/hy2.txt" "$D/naive.txt" \
		"$D/wg.conf" "$D/wg.json" \
		"$D/proto" "$D/server_ip" "$D/mode" \
		"$HYD/client.yaml" "$HYD/client.yaml.prev"
	do
		[ -e "$f" ] && cp -a "$f" "$B/"
	done
	[ -e "$NAD/config.json" ] && cp -a "$NAD/config.json" "$B/naive-config.json"
	[ -e "$NAD/config.json.prev" ] && cp -a "$NAD/config.json.prev" "$B/naive-config.json.prev"
}

au_restore_file() {
	# backup_dir dest_path [backup_basename]
	src="$1/${3:-$(basename "$2")}"
	[ -e "$src" ] || return 0
	mkdir -p "$(dirname "$2")"
	cp -a "$src" "$2"
}

au_restore() {
	B=$1
	[ -d "$B" ] || return 1
	au_restore_file "$B" "$D/config.json"
	au_restore_file "$B" "$D/config.prev.json"
	au_restore_file "$B" "$D/link.txt"
	au_restore_file "$B" "$D/hy2.txt"
	au_restore_file "$B" "$D/naive.txt"
	au_restore_file "$B" "$D/wg.conf"
	au_restore_file "$B" "$D/wg.json"
	au_restore_file "$B" "$D/proto"
	au_restore_file "$B" "$D/server_ip"
	au_restore_file "$B" "$D/mode"
	au_restore_file "$B" "$HYD/client.yaml"
	au_restore_file "$B" "$HYD/client.yaml.prev"
	au_restore_file "$B" "$NAD/config.json" naive-config.json
	au_restore_file "$B" "$NAD/config.json.prev" naive-config.json.prev
}

# Idempotent cron line in /etc/crontabs/root.
au_cron_line() {
	printf '0 * * * * %s # %s\n' "$AU_RUN" "$AU_CRON_MARK"
}

au_cron_install() {
	mkdir -p "$(dirname "$AU_CRON")"
	touch "$AU_CRON"
	if grep -q "$AU_CRON_MARK" "$AU_CRON" 2>/dev/null; then
		return 0
	fi
	au_cron_line >> "$AU_CRON"
	[ -n "${IPKG_INSTROOT:-}" ] && return 0
	if [ -x /etc/init.d/cron ]; then
		/etc/init.d/cron enable >/dev/null 2>&1 || true
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	fi
}

au_cron_remove() {
	[ -f "$AU_CRON" ] || return 0
	grep -q "$AU_CRON_MARK" "$AU_CRON" 2>/dev/null || return 0
	# Busybox sed -i is available on OpenWrt 23.05.
	sed -i "/$AU_CRON_MARK/d" "$AU_CRON"
	[ -n "${IPKG_INSTROOT:-}" ] && return 0
	if [ -x /etc/init.d/cron ]; then
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	fi
}
