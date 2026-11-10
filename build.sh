#!/bin/sh
# Rebuild the OpenWrt .ipk and the opkg feed index under feed/all/.
# Requires GNU tar and gzip. Reproducible: fixed mtime, owner root:root, gzip -n.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PKG=$(sed -n 's/^Package: //p' "$ROOT/control/control" | head -1)
VER=$(sed -n 's/^Version: //p' "$ROOT/control/control" | head -1)
ARCH=$(sed -n 's/^Architecture: //p' "$ROOT/control/control" | head -1)
IPK_NAME="${PKG}_${VER}_${ARCH}.ipk"
FEED="$ROOT/feed/all"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

# Fixed timestamp so Packages SHA256sum stays stable across rebuilds.
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1794268800} # 2026-11-10 00:00:00 UTC
export LC_ALL=C
TAR="tar --format=gnu --sort=name --owner=0 --group=0 --numeric-owner --mtime=@${SOURCE_DATE_EPOCH}"

# --- data.tar.gz ---
DATA="$STAGING/data"
mkdir -p "$DATA"
# Copy tree, then re-apply permissions so a checkout without the exec bit
# (e.g. on some CI runners) still produces a correct package.
cp -a "$ROOT/files/." "$DATA/"
chmod 644 "$DATA/www-vless/index.html" \
          "$DATA/etc/xray/gen.uc" \
          "$DATA/etc/xray/hy2.uc"
chmod 644 "$DATA/usr/libexec/vless-panel/autoupdate-lib.sh"
chmod 755 "$DATA/www-vless/cgi-bin/vless" \
          "$DATA/etc/xray/vless.sh" \
          "$DATA/etc/xray/tproxy.sh" \
          "$DATA/etc/init.d/xray-client" \
          "$DATA/etc/init.d/hysteria-client" \
          "$DATA/etc/init.d/naive-client" \
          "$DATA/usr/libexec/vless-panel/install-naive.sh" \
          "$DATA/usr/libexec/vless-panel/autoupdate-run.sh"

# Syntax-check shipped shell scripts (POSIX sh).
for s in \
  "$DATA/www-vless/cgi-bin/vless" \
  "$DATA/etc/xray/vless.sh" \
  "$DATA/etc/xray/tproxy.sh" \
  "$DATA/etc/init.d/xray-client" \
  "$DATA/etc/init.d/hysteria-client" \
  "$DATA/etc/init.d/naive-client" \
  "$DATA/usr/libexec/vless-panel/install-naive.sh" \
  "$DATA/usr/libexec/vless-panel/autoupdate-run.sh" \
  "$DATA/usr/libexec/vless-panel/autoupdate-lib.sh" \
  "$ROOT/control/postinst" "$ROOT/control/prerm" "$ROOT/control/postrm" \
  "$ROOT/build.sh"
do
  sh -n "$s" || { echo "ERROR: sh -n failed for $s" >&2; exit 1; }
done

# Fail if we accidentally staged user-state files.

for f in \
  etc/xray/link.txt etc/xray/config.json etc/xray/hy2.txt \
  etc/xray/naive.txt etc/xray/wg.conf etc/xray/wg.json \
  etc/xray/server_ip etc/xray/mode etc/xray/proto \
  etc/xray/httpd.conf etc/hysteria/client.yaml \
  etc/naive/config.json
do
  if [ -e "$DATA/$f" ]; then
    echo "ERROR: refusing to ship user-state file $f" >&2
    exit 1
  fi
done
if [ -d "$DATA/etc/xray/autoupdate" ]; then
  echo "ERROR: refusing to ship user autoupdate state under etc/xray/autoupdate" >&2
  exit 1
fi
# Installed-Size is unpacked payload size in KiB (1024-byte).
UNPACKED=$(find "$DATA" -type f -exec stat -c %s {} + | awk '{s+=$1} END {print s+0}')
INSTALLED_SIZE=$(( (UNPACKED + 1023) / 1024 ))

( cd "$DATA" && $TAR -cf - . | gzip -n > "$STAGING/data.tar.gz" )

# --- control.tar.gz ---
CTRL="$STAGING/control"
mkdir -p "$CTRL"
# Inject Installed-Size after Architecture (OpenWrt convention).
awk -v size="$INSTALLED_SIZE" '
  { print }
  /^Architecture:/ { print "Installed-Size: " size }
' "$ROOT/control/control" > "$CTRL/control"
cp "$ROOT/control/postinst" "$CTRL/postinst"
cp "$ROOT/control/prerm" "$CTRL/prerm"
cp "$ROOT/control/postrm" "$CTRL/postrm"
chmod 755 "$CTRL/postinst" "$CTRL/prerm" "$CTRL/postrm"
# No conffiles: package does not ship user state.

( cd "$CTRL" && $TAR -cf - ./control ./postinst ./prerm ./postrm | gzip -n > "$STAGING/control.tar.gz" )

# --- outer ipk (gzip-compressed tar, OpenWrt 23.05) ---
printf '2.0\n' > "$STAGING/debian-binary"
( cd "$STAGING" && $TAR -cf - ./debian-binary ./control.tar.gz ./data.tar.gz | gzip -n > "$STAGING/$IPK_NAME" )

mkdir -p "$FEED"
rm -f "$FEED"/*.ipk
cp "$STAGING/$IPK_NAME" "$FEED/$IPK_NAME"
SIZE=$(stat -c %s "$FEED/$IPK_NAME")
SHA256=$(sha256sum "$FEED/$IPK_NAME" | awk '{print $1}')

# --- Packages / Packages.gz ---
# Filename is relative to the feed directory.
{
  cat "$CTRL/control"
  echo "Filename: $IPK_NAME"
  echo "Size: $SIZE"
  echo "SHA256sum: $SHA256"
  echo
} > "$FEED/Packages"
gzip -n -c "$FEED/Packages" > "$FEED/Packages.gz"

# --- verify by extracting back ---
VERIFY="$STAGING/verify"
mkdir -p "$VERIFY/outer" "$VERIFY/ctrl" "$VERIFY/data"
# Outer archive must be a gzip tar whose first three members are, in order,
# ./debian-binary ./control.tar.gz ./data.tar.gz (what OpenWrt opkg expects).
ORDER=$(gzip -dc "$FEED/$IPK_NAME" | tar -tf - | tr '\n' ' ')
[ "$ORDER" = "./debian-binary ./control.tar.gz ./data.tar.gz " ] || { echo "ERROR: bad ipk member order: $ORDER" >&2; exit 1; }
gzip -dc "$FEED/$IPK_NAME" | tar -C "$VERIFY/outer" -xf -
printf '2.0\n' > "$STAGING/expected-debian-binary"
cmp "$STAGING/expected-debian-binary" "$VERIFY/outer/debian-binary"
gzip -dc "$VERIFY/outer/control.tar.gz" | tar -C "$VERIFY/ctrl" -xf -
gzip -dc "$VERIFY/outer/data.tar.gz" | tar -C "$VERIFY/data" -xf -

# Check required data paths and modes.
# Syntax-check every shipped shell script before packing is enough
# on the host; also verify modes after extract.
test -x "$VERIFY/data/www-vless/cgi-bin/vless"
test -x "$VERIFY/data/etc/xray/vless.sh"
test -x "$VERIFY/data/etc/xray/tproxy.sh"
test -x "$VERIFY/data/etc/init.d/xray-client"
test -x "$VERIFY/data/etc/init.d/hysteria-client"
test -x "$VERIFY/data/etc/init.d/naive-client"
test -x "$VERIFY/data/usr/libexec/vless-panel/install-naive.sh"
test -x "$VERIFY/data/usr/libexec/vless-panel/autoupdate-run.sh"
test -f "$VERIFY/data/usr/libexec/vless-panel/autoupdate-lib.sh"
if [ -e "$VERIFY/data/usr/libexec/vless-panel/autoupdate-server" ]; then
  echo "ERROR: autoupdate-server must not be shipped (server source removed)" >&2
  exit 1
fi
test -f "$VERIFY/data/www-vless/index.html"
test -f "$VERIFY/data/etc/xray/gen.uc"
test -f "$VERIFY/data/etc/xray/hy2.uc"
# The naive binary must never be inside the package.
if find "$VERIFY/data" -type f -name naive | grep -q .; then
  echo "ERROR: refusing to ship a naive binary in the package" >&2
  exit 1
fi
test -x "$VERIFY/ctrl/postinst"
test -x "$VERIFY/ctrl/prerm"
test -x "$VERIFY/ctrl/postrm"
grep -q "^Package: $PKG$" "$VERIFY/ctrl/control"
grep -q "^Version: $VER$" "$VERIFY/ctrl/control"
grep -q "^Architecture: all$" "$VERIFY/ctrl/control"
# Owner must be root (uid 0). GNU tar --numeric-owner stored that.
UID0=$(tar -tzvf "$VERIFY/outer/data.tar.gz" | awk '{print $2}' | head -1)
# Field 2 is typically "0/0" or "root/root" depending on tar.
case "$UID0" in
  0/0|root/root|0/root|root/0) ;;
  *)
    echo "ERROR: data.tar.gz members are not root:root (got: $UID0)" >&2
    exit 1
    ;;
esac

if [ -x "$ROOT/tests/autoupdate.sh" ]; then
  "$ROOT/tests/autoupdate.sh" || { echo "ERROR: autoupdate tests failed" >&2; exit 1; }
fi

echo "Built $FEED/$IPK_NAME"
echo "Size: $SIZE"
echo "SHA256sum: $SHA256"
echo "Installed-Size: $INSTALLED_SIZE KiB"
echo "Verified: extracted ipk, control, and data look correct."
