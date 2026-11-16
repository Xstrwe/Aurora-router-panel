#!/bin/sh
# aurora-geoip.sh <cc>  -> IPv4 CIDRs of country <cc> from geoip.dat, one per line.
# The result is cached in $AURORA_GEO_CACHE/<cc>.txt and rebuilt when geoip.dat is newer.
# geoip.dat is a protobuf: repeated GeoIP { string country_code = 1; repeated CIDR cidr = 2 }
# with CIDR { bytes ip = 1; uint32 prefix = 2 }; it is parsed with dd/tail/awk and od or hexdump (BusyBox on OpenWrt has hexdump only) (no extra tools).
DAT=${AURORA_GEOIP_DAT:-/usr/share/xray/geoip.dat}
CACHE=${AURORA_GEO_CACHE:-/etc/aurora/geoip}
cc=$(printf '%s' "$1" | tr 'a-z' 'A-Z')
[ -n "$cc" ] || { echo "usage: aurora-geoip.sh <cc>" >&2; exit 2; }
out=$CACHE/$cc.txt
# one byte per line, decimal
bytes() {
	if command -v od >/dev/null 2>&1; then od -An -v -tu1 -w1; else hexdump -v -e '/1 "%u\n"'; fi
}
if [ -s "$out" ] && [ -f "$DAT" ] && [ ! "$DAT" -nt "$out" ]; then cat "$out"; exit 0; fi
[ -f "$DAT" ] || { [ -s "$out" ] && { cat "$out"; exit 0; }; echo "no geoip data ($DAT)" >&2; exit 1; }
size=$(wc -c < "$DAT" | tr -d ' ')
pos=0; start=""; len=0
while [ "$pos" -lt "$size" ]; do
	# header: tag, varint length, then the nested country_code field (tag, length, bytes)
	hdr=$(dd if="$DAT" bs=1 skip="$pos" count=24 2>/dev/null | bytes | tr '\n' ' ')
	set -- $hdr
	[ "$1" = 10 ] || break
	shift
	l=0; sh=1
	while :; do b=$1; shift; l=$((l + (b % 128) * sh)); sh=$((sh * 128)); [ "$b" -ge 128 ] || break; done
	hl=$((24 - $# - 0))   # bytes consumed so far = 24 - remaining
	[ "$1" = 10 ] || break
	cl=$2
	code=$(dd if="$DAT" bs=1 skip=$((pos + hl + 2)) count="$cl" 2>/dev/null | tr 'a-z' 'A-Z')
	if [ "$code" = "$cc" ]; then start=$((pos + hl)); len=$l; break; fi
	pos=$((pos + hl + l))
done
[ -n "$start" ] || { echo "country $cc not found in $DAT" >&2; exit 1; }
mkdir -p "$CACHE" 2>/dev/null
tail -c +$((start + 1)) "$DAT" | head -c "$len" | bytes | awk '
{ b[n++] = $1 }
END {
	p = 0
	# country_code field: tag, len, bytes
	if (b[p] == 10) p += 2 + b[p + 1]
	while (p < n) {
		if (b[p] != 18) break
		cl = b[p + 1]; p += 2; e = p + cl
		ip = ""; pre = -1; v6 = 0
		while (p < e) {
			if (b[p] == 10) { il = b[p + 1]; if (il != 4) v6 = 1; if (il == 4) ip = b[p + 2] "." b[p + 3] "." b[p + 4] "." b[p + 5]; p += 2 + il }
			else if (b[p] == 16) { pre = b[p + 1]; p += 2 }
			else break
		}
		p = e
		if (!v6 && ip != "" && pre >= 0) print ip "/" pre
	}
}' > "$out.tmp.$$" && [ -s "$out.tmp.$$" ] && mv "$out.tmp.$$" "$out" || { rm -f "$out.tmp.$$"; echo "could not parse $DAT" >&2; exit 1; }
cat "$out"
