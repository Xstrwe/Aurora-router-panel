#!/bin/sh
# opkg-compatible version ordering, release classification and feed index tests.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VC=$ROOT/tools/vercmp.sh
fail=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }

# --- ordering: every earlier entry is lower than every later one ---
ORDER="1.3.0 1.3.0a1 1.3.0a2 1.3.0a10 1.3.0b1 1.4.0"
set -- $ORDER
n=$#
i=1
bad_pairs=0
for a in "$@"; do
	j=1
	for b in "$@"; do
		want=0
		[ "$i" -lt "$j" ] && want=-1
		[ "$i" -gt "$j" ] && want=1
		got=$("$VC" cmp "$a" "$b")
		[ "$got" = "$want" ] || { bad "cmp $a $b: got $got, want $want"; bad_pairs=$((bad_pairs+1)); }
		j=$((j+1))
	done
	i=$((i+1))
done
[ "$bad_pairs" -eq 0 ] && ok "ordering $ORDER ($n versions, all $((n*n)) pairs)"

# --- more opkg/dpkg rules ---
chk() { # a b expected
	got=$("$VC" cmp "$1" "$2")
	if [ "$got" = "$3" ]; then ok "cmp $1 $2 = $3"; else bad "cmp $1 $2: got $got, want $3"; fi
}
chk 1.3.0 1.3.0 0
chk 1.9.0 1.10.0 -1
chk 1.3.0a9 1.3.0a10 -1
chk 1.3.0a1 1.3.0~rc1 1
chk 1.3.0~rc1 1.3.0 -1
chk 1.3.0 1.3.0-1 -1
chk 1:0.1 2.0 1
chk 2.0.0 1.99.99 1
chk 1.3.01 1.3.1 0

# --- max ---
m=$("$VC" max 1.3.0 1.3.0a10 1.3.0a2 1.3.0b1 1.2.9)
if [ "$m" = 1.3.0b1 ]; then ok "max picks 1.3.0b1"; else bad "max ($m)"; fi

# --- cross-check against dpkg when it is installed (same algorithm) ---
if command -v dpkg >/dev/null 2>&1; then
	pairs=0; diff=0
	for a in 1.3.0 1.3.0a1 1.3.0a2 1.3.0a10 1.3.0b1 1.4.0 1.3.1 1.3.0~rc1 1.3.0+x 1.3.0-1 1:0.1 0.9 1.3.0A1; do
		for b in 1.3.0 1.3.0a1 1.3.0a2 1.3.0a10 1.3.0b1 1.4.0 1.3.1 1.3.0~rc1 1.3.0+x 1.3.0-1 1:0.1 0.9 1.3.0A1; do
			if dpkg --compare-versions "$a" lt "$b"; then d=-1
			elif dpkg --compare-versions "$a" gt "$b"; then d=1
			else d=0; fi
			g=$("$VC" cmp "$a" "$b")
			pairs=$((pairs+1))
			[ "$g" = "$d" ] || { diff=$((diff+1)); echo "  differs from dpkg: $a $b mine=$g dpkg=$d"; }
		done
	done
	if [ "$diff" -eq 0 ]; then ok "agrees with dpkg on $pairs pairs"; else bad "$diff pairs differ from dpkg"; fi
else
	echo "skip - dpkg not installed, no cross-check"
fi

# --- release classification ---
cls() {
	got=$("$VC" classify "$1")
	if [ "$got" = "$2" ]; then ok "classify $1 = $2"; else bad "classify $1: got $got, want $2"; fi
}
cls 1.3.0 full
cls 2.0.0 full
cls 1.3.0a1 pre
cls 1.3.0b12 pre
cls 1.3.1a1 pre
cls 1.3.1 none
cls 1.3 none
cls 1.3.0-rc1 none
cls 1.3.0A1 none
cls 1.3.0a none

# --- feed index: newest version listed, older ipks kept ---
SRC=$(sed -n 's/^Version: //p' "$ROOT/control/control" | head -1)
IPK=$ROOT/feed/all/aurora-router-panel_${SRC}_all.ipk
if [ -f "$IPK" ]; then
	T=$(mktemp -d)
	trap 'rm -rf "$T"' EXIT
	mk() { # version -> $T/feed/aurora-router-panel_<version>_all.ipk with that Version
		w=$T/w.$1
		mkdir -p "$w/o" "$w/c" "$T/feed"
		gzip -dc "$IPK" | tar -C "$w/o" -xf -
		gzip -dc "$w/o/control.tar.gz" | tar -C "$w/c" -xf -
		sed -i "s/^Version: .*/Version: $1/" "$w/c/control"
		( cd "$w/c" && tar --format=gnu --sort=name --owner=0 --group=0 --numeric-owner -cf - ./control ./postinst ./prerm ./postrm | gzip -n > "$w/o/control.tar.gz" )
		( cd "$w/o" && tar --format=gnu --owner=0 --group=0 --numeric-owner -cf - ./debian-binary ./control.tar.gz ./data.tar.gz | gzip -n > "$T/feed/aurora-router-panel_$1_all.ipk" )
	}
	for v in 1.3.0 1.3.0a2 1.3.0a10 1.3.0a1; do mk "$v"; done
	if "$ROOT/tools/mkfeed.sh" "$T/feed" 2>/dev/null \
	   && [ "$(grep -c '^Package: ' "$T/feed/Packages")" = 1 ] \
	   && grep -qx 'Version: 1.3.0a10' "$T/feed/Packages" \
	   && grep -qx 'Filename: aurora-router-panel_1.3.0a10_all.ipk' "$T/feed/Packages" \
	   && grep -qx "SHA256sum: $(sha256sum "$T/feed/aurora-router-panel_1.3.0a10_all.ipk" | awk '{print $1}')" "$T/feed/Packages" \
	   && [ "$(ls "$T"/feed/*.ipk | wc -l)" = 4 ] \
	   && gzip -dc "$T/feed/Packages.gz" | cmp -s - "$T/feed/Packages"; then
		ok "feed index lists only 1.3.0a10, all 4 ipks are kept, Packages.gz matches"
	else
		bad "feed index (Packages: $(grep -E '^(Version|Filename)' "$T/feed/Packages" 2>/dev/null | tr '\n' ' '))"
	fi
	# the index of the real build is identical to the one build.sh wrote
	rm -rf "$T/real" && mkdir -p "$T/real" && cp "$IPK" "$T/real/"
	"$ROOT/tools/mkfeed.sh" "$T/real" 2>/dev/null
	if cmp -s "$T/real/Packages" "$ROOT/feed/all/Packages"; then
		ok "mkfeed.sh output equals the Packages written by build.sh"
	else
		bad "mkfeed.sh differs from build.sh Packages"
	fi
else
	echo "skip - $IPK not built yet (run build.sh first), feed index tests skipped"
fi

for s in "$VC" "$ROOT/tools/mkfeed.sh"; do
	if sh -n "$s"; then ok "sh -n $(basename "$s")"; else bad "sh -n $(basename "$s")"; fi
done

if [ "$fail" -ne 0 ]; then
	echo "FAILED: $fail test(s)"
	exit 1
fi
echo "All version tests passed."
