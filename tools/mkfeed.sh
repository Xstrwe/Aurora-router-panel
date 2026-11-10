#!/bin/sh
# Write the opkg index for a feed directory that holds one or more .ipk files
# (possibly several versions of the same package).
#
#   mkfeed.sh <feeddir>
#
# Packages / Packages.gz list only the newest version of each package (compared
# with the opkg algorithm in vercmp.sh); the older .ipk files stay in the
# directory, so they can still be downloaded by file name.
# The Packages stanza has the same layout as the one build.sh writes.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DIR=${1:?usage: mkfeed.sh <feeddir>}
[ -d "$DIR" ] || { echo "mkfeed: no such directory: $DIR" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# control file of an .ipk (gzip tar -> ./control.tar.gz -> ./control)
ipk_control() {
	rm -rf "$TMP/x"
	mkdir -p "$TMP/x"
	gzip -dc "$1" | tar -C "$TMP/x" -xf - ./control.tar.gz
	gzip -dc "$TMP/x/control.tar.gz" | tar -C "$TMP/x" -xf - ./control
	cat "$TMP/x/control"
}

: > "$TMP/list"
for f in "$DIR"/*.ipk; do
	[ -e "$f" ] || continue
	c=$(ipk_control "$f")
	pkg=$(printf '%s\n' "$c" | sed -n 's/^Package: //p' | head -1)
	ver=$(printf '%s\n' "$c" | sed -n 's/^Version: //p' | head -1)
	[ -n "$pkg" ] && [ -n "$ver" ] || { echo "mkfeed: bad control in $f" >&2; exit 1; }
	printf '%s %s %s\n' "$pkg" "$ver" "$(basename "$f")" >> "$TMP/list"
done
[ -s "$TMP/list" ] || { echo "mkfeed: no .ipk files in $DIR" >&2; exit 1; }

: > "$TMP/Packages"
for pkg in $(cut -d' ' -f1 "$TMP/list" | sort -u); do
	vers=$(awk -v p="$pkg" '$1 == p { print $2 }' "$TMP/list")
	# shellcheck disable=SC2086
	best=$("$HERE/vercmp.sh" max $vers)
	file=$(awk -v p="$pkg" -v v="$best" '$1 == p && $2 == v { print $3; exit }' "$TMP/list")
	size=$(stat -c %s "$DIR/$file")
	sum=$(sha256sum "$DIR/$file" | awk '{print $1}')
	{
		ipk_control "$DIR/$file"
		echo "Filename: $file"
		echo "Size: $size"
		echo "SHA256sum: $sum"
		echo
	} >> "$TMP/Packages"
	echo "mkfeed: $pkg $best ($file); older files kept: $(printf '%s\n' $vers | grep -vxF "$best" | tr '\n' ' ')" >&2
done

cp "$TMP/Packages" "$DIR/Packages"
gzip -n -c "$DIR/Packages" > "$DIR/Packages.gz"
