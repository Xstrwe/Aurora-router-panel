#!/bin/sh
# Version helpers for releases. POSIX sh + awk, no other dependencies.
#
#   vercmp.sh cmp A B        print -1, 0 or 1 (A <, = or > B), like opkg
#   vercmp.sh max V...       print the greatest version
#   vercmp.sh classify V     print "full" (X.Y.0), "pre" (X.Y.Z<letter><digits>) or "none"
#
# The comparison is a port of verrevcmp()/order() from opkg (libopkg/pkg.c),
# which is the dpkg algorithm: [epoch:]upstream[-revision]; digit runs compare
# numerically, letters sort before any other character, "~" sorts before
# everything, and the end of a string sorts before a letter. So
# 1.3.0 < 1.3.0a1 < 1.3.0a2 < 1.3.0a10 < 1.3.0b1 < 1.4.0.
set -eu

vercmp() {
	awk -v a="$1" -v b="$2" '
	# ASCII code of a printable character (space is 32).
	function ord(c) { return index(CH, c) + 31 }
	function order(c) {
		if (c == "") return 0
		if (c ~ /^[0-9]$/) return 0
		if (c ~ /^[A-Za-z]$/) return ord(c)
		if (c == "~") return -1
		return ord(c) + 256
	}
	function isdig(c) { return c ~ /^[0-9]$/ }
	function verrevcmp(v, r,   i, j, fd, vc, rc, cv, cr) {
		i = 1; j = 1
		while (i <= length(v) || j <= length(r)) {
			fd = 0
			while ((i <= length(v) && !isdig(substr(v, i, 1))) || (j <= length(r) && !isdig(substr(r, j, 1)))) {
				vc = order(substr(v, i, 1)); rc = order(substr(r, j, 1))
				if (vc != rc) return vc - rc
				i++; j++
			}
			while (substr(v, i, 1) == "0") i++
			while (substr(r, j, 1) == "0") j++
			while (isdig(substr(v, i, 1)) && isdig(substr(r, j, 1))) {
				if (!fd) fd = substr(v, i, 1) - substr(r, j, 1)
				i++; j++
			}
			if (isdig(substr(v, i, 1))) return 1
			if (isdig(substr(r, j, 1))) return -1
			if (fd) return fd
		}
		return 0
	}
	function split_ver(s, out,   n, e, rev) {
		e = 0; rev = ""
		n = index(s, ":")
		if (n) { e = substr(s, 1, n - 1) + 0; s = substr(s, n + 1) }
		n = 0
		for (k = length(s); k >= 1; k--) if (substr(s, k, 1) == "-") { n = k; break }
		if (n) { rev = substr(s, n + 1); s = substr(s, 1, n - 1) }
		out[1] = e; out[2] = s; out[3] = rev
	}
	BEGIN {
		CH = " !\"#$%&\047()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
		split_ver(a, x); split_ver(b, y)
		r = x[1] - y[1]
		if (r == 0) r = verrevcmp(x[2], y[2])
		if (r == 0) r = verrevcmp(x[3], y[3])
		print (r < 0 ? -1 : (r > 0 ? 1 : 0))
	}'
}

case "${1:-}" in
cmp)
	[ $# -eq 3 ] || { echo "usage: $0 cmp A B" >&2; exit 2; }
	vercmp "$2" "$3"
	;;
max)
	shift
	[ $# -ge 1 ] || { echo "usage: $0 max V..." >&2; exit 2; }
	best=$1
	shift
	for v in "$@"; do
		[ "$(vercmp "$v" "$best")" = 1 ] && best=$v
	done
	printf '%s\n' "$best"
	;;
classify)
	[ $# -eq 2 ] || { echo "usage: $0 classify V" >&2; exit 2; }
	if printf '%s\n' "$2" | grep -Eq '^[0-9]+\.[0-9]+\.0$'; then echo full
	elif printf '%s\n' "$2" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+[a-z][0-9]+$'; then echo pre
	else echo none
	fi
	;;
*)
	echo "usage: $0 cmp A B | max V... | classify V" >&2
	exit 2
	;;
esac
