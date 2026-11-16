#!/bin/sh
# Build the OpenWrt apk package (apk-tools 3 / APKv3) from the same payload as the .ipk.
# For OpenWrt 25.x and main, which use apk instead of opkg. EXPERIMENTAL: not on the
# published feed and not part of a release; it is built as a file (and a CI artifact) only.
#
#   build-apk.sh [build]       build $APK_OUT/aurora-router-panel-<apk version>.apk
#   build-apk.sh version [V]   print the apk version for package version V (default: control)
#
# How it is built: the official way. OpenWrt's package-pack.mk calls
#   apk mkpkg --info name:... --info version:... --info depends:... --script post-install:...
#             --files <package root> --output <file>.apk
# under fakeroot, with the apk-tools that OpenWrt itself uses (3.0.x, pinned in CI to the
# commit of package/system/apk). This script runs the same `apk mkpkg` call, with the same
# fields and script layout, and takes the files from the .ipk that build.sh has just built and
# verified, so both packages carry identical files, modes and owners (root:root).
#
# Environment:
#   APK            apk binary (default: apk)
#   APK_OUT        output directory (default: <repo>/build/apk)
#   APK_SIGN_KEY   optional private key (PEM) to sign the package with (apk mkpkg --sign)
#   SOURCE_DATE_EPOCH  fixed timestamp for a reproducible file (default as build.sh)
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

# Package version -> apk version. apk versions are NUMBER{.NUMBER}[LETTER][_SUFFIX[N]][-rN]:
# a pre-release such as 1.5.0a5 is written 1.5.0_alpha5 (a=alpha, b=beta, c=pre, d=rc), and
# every package gets the build revision -r1 like the OpenWrt packages. A plain 1.5.0 is 1.5.0-r1.
# In apk order 1.5.0_alpha5 < 1.5.0, so the full release replaces its own pre-releases.
apk_version() {
	case "$1" in
		[0-9]*.[0-9]*.[0-9]*[a-z][0-9]*) ;;
		[0-9]*.[0-9]*.[0-9]*) echo "$1-r1"; return 0 ;;
		*) echo "cannot map version '$1' to an apk version" >&2; return 1 ;;
	esac
	_n=$(printf '%s' "$1" | sed 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[a-z][0-9][0-9]*$/\1/')
	_l=$(printf '%s' "$1" | sed 's/^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\([a-z]\)[0-9][0-9]*$/\1/')
	_d=$(printf '%s' "$1" | sed 's/^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*[a-z]\([0-9][0-9]*\)$/\1/')
	case "$_l" in
		a) _s=alpha ;; b) _s=beta ;; c) _s=pre ;; d) _s=rc ;;
		*) echo "cannot map version '$1' to an apk version (letter '$_l')" >&2; return 1 ;;
	esac
	echo "${_n}_${_s}${_d}-r1"
}

CTRL=$ROOT/control/control
PKG=$(sed -n 's/^Package: //p' "$CTRL" | head -1)
VER=$(sed -n 's/^Version: //p' "$CTRL" | head -1)

case "${1:-build}" in
	version) apk_version "${2:-$VER}"; exit $? ;;
	build) ;;
	*) echo "usage: build-apk.sh [build | version [V]]" >&2; exit 2 ;;
esac

APK=${APK:-apk}
OUT=${APK_OUT:-$ROOT/build/apk}
APKVER=$(apk_version "$VER")
IPK=$ROOT/feed/all/${PKG}_${VER}_all.ipk
[ -f "$IPK" ] || { echo "ERROR: $IPK not found; run ./build.sh first" >&2; exit 1; }
command -v "$APK" >/dev/null 2>&1 || { echo "ERROR: apk binary '$APK' not found (apk-tools 3 is required, see INSTALL.md)" >&2; exit 1; }
"$APK" --version | grep -q 'apk-tools 3\.' || { echo "ERROR: apk-tools 3 is required, got: $("$APK" --version)" >&2; exit 1; }
"$APK" version -c "$APKVER" | grep -q . && { echo "ERROR: $APKVER is not a valid apk version" >&2; exit 1; }
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1794268800}
export SOURCE_DATE_EPOCH

# Dependencies: same names as in control/control. Version constraints are not used there.
FIELD() { sed -n "s/^$1: //p" "$CTRL" | head -1; }
DEPENDS=$(FIELD Depends | tr -d ' ')
REPLACES=$(FIELD Replaces | tr -d ' ')
CONFLICTS=$(FIELD Conflicts | tr -d ' ')
# apk: a conflict is a "!name" dependency.
APKDEPENDS=$DEPENDS
for c in $(printf '%s' "$CONFLICTS" | tr ',' ' '); do APKDEPENDS="$APKDEPENDS,!$c"; done
APKDEPENDS=$(printf '%s' "$APKDEPENDS" | tr ',' ' ')
LICENSE=$(FIELD License)
URL=$(FIELD Source)
MAINT=$(FIELD Maintainer | sed 's# *<.*>##')
DESC="Aurora router panel: web page on port 8088 to run a transparent VPN proxy (VLESS, Hysteria 2, Naive, WireGuard) on OpenWrt"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
S=$WORK/scripts
mkdir -p "$S" "$OUT" "$WORK/root"

# --- scripts: opkg postinst/prerm/postrm -> apk script types (as package-pack.mk does) ---
# opkg ownership self-heal (the block that edits /usr/lib/opkg/info/*.list) does not apply to apk.
awk '
	/^# When this package replaces vless-router-panel/ { skip = 1 }
	skip { if ($0 == "fi") { skip = 0 } ; next }
	{ print }
' "$ROOT/control/postinst" > "$WORK/postinst.body"
# The panel address defaults to 192.168.8.1 (GL.iNet). On other firmware use the LAN address of the router.
awk '
	/^LISTEN=.192\.168\.8\.1:8088.$/ {
		print "LAN_IP=$(uci -q get network.lan.ipaddr | awk \047{print $1}\047 | cut -d/ -f1)"
		print "LISTEN=\"${LAN_IP:-192.168.8.1}:8088\""
		next
	}
	{ print }
' "$WORK/postinst.body" > "$WORK/postinst.body2"
mv "$WORK/postinst.body2" "$WORK/postinst.body"
grep -q 'opkg' "$WORK/postinst.body" && { echo "ERROR: opkg-specific code left in the apk post-install" >&2; exit 1; }
grep -q 'LAN_IP=' "$WORK/postinst.body" || { echo "ERROR: could not adapt the panel listen address for apk" >&2; exit 1; }
grep -q '@FILES@' "$WORK/postinst.body" && { echo "ERROR: unexpanded @FILES@ left in the apk post-install" >&2; exit 1; }
strip_shebang() { sed '/^[[:space:]]*#!/d' "$1"; }
{ echo '#!/bin/sh'; strip_shebang "$WORK/postinst.body"; } > "$S/post-install"
{ echo '#!/bin/sh'; echo 'export PKG_UPGRADE=1'; strip_shebang "$WORK/postinst.body"; } > "$S/post-upgrade"
{ echo '#!/bin/sh'; strip_shebang "$ROOT/control/prerm"; } > "$S/pre-deinstall"
{ echo '#!/bin/sh'; strip_shebang "$ROOT/control/postrm"; } > "$S/post-deinstall"
for f in post-install post-upgrade pre-deinstall post-deinstall; do
	sh -n "$S/$f" || { echo "ERROR: syntax error in generated apk script $f" >&2; exit 1; }
	chmod 755 "$S/$f"
done

SIGN=
[ -z "${APK_SIGN_KEY:-}" ] || SIGN="--sign $APK_SIGN_KEY"
APKFILE=$OUT/${PKG}-${APKVER}.apk

# --- payload + mkpkg, as root:root (fakeroot like OpenWrt; user namespace or real root as fallbacks) ---
cat > "$WORK/inner.sh" <<'INNER'
set -eu
gzip -dc "$IPK" | tar -C "$WORK" -xf - ./data.tar.gz
tar -C "$WORK/root" -xzpf "$WORK/data.tar.gz"
# /lib/apk/packages/<name>.list: the file list OpenWrt keeps for every apk package.
mkdir -p "$WORK/root/lib/apk/packages"
( cd "$WORK/root" && find . -type f,l -printf '/%P\n' | LC_ALL=C sort ) > "$WORK/pkg.list"
mv "$WORK/pkg.list" "$WORK/root/lib/apk/packages/$PKG.list"
chmod 644 "$WORK/root/lib/apk/packages/$PKG.list"
# shellcheck disable=SC2086
"$APK" mkpkg \
	--info "name:$PKG" \
	--info "version:$APKVER" \
	--info "description:$DESC" \
	--info "arch:noarch" \
	--info "license:$LICENSE" \
	--info "origin:$PKG" \
	--info "url:$URL" \
	--info "maintainer:$MAINT" \
	--info "replaces:$REPLACES" \
	--info "depends:$APKDEPENDS" \
	--script "post-install:$S/post-install" \
	--script "post-upgrade:$S/post-upgrade" \
	--script "pre-deinstall:$S/pre-deinstall" \
	--script "post-deinstall:$S/post-deinstall" \
	--files "$WORK/root" \
	$SIGN \
	--output "$APKFILE"
INNER
export IPK WORK PKG APK APKVER DESC LICENSE URL MAINT REPLACES APKDEPENDS S SIGN APKFILE
if [ "$(id -u)" = 0 ]; then sh "$WORK/inner.sh"
elif command -v fakeroot >/dev/null 2>&1; then fakeroot sh "$WORK/inner.sh"
elif unshare -Ur true 2>/dev/null; then unshare -Ur sh "$WORK/inner.sh"
else echo "ERROR: need fakeroot, root or user namespaces to write root-owned files" >&2; exit 1; fi

[ -f "$APKFILE" ] || { echo "ERROR: $APKFILE was not created" >&2; exit 1; }

# --- verify: read the package back ---
"$APK" adbdump "$APKFILE" > "$WORK/dump.txt"
grep -q "name: $PKG\$" "$WORK/dump.txt"
grep -q "version: $APKVER\$" "$WORK/dump.txt"
grep -q 'arch: noarch' "$WORK/dump.txt"
grep -q 'post-install' "$WORK/dump.txt"
if grep -E '^ *(user|group): ' "$WORK/dump.txt" | grep -qv ': root$'; then echo "ERROR: the package has files that are not owned by root:root" >&2; exit 1; fi

SIZE=$(stat -c %s "$APKFILE")
SHA256=$(sha256sum "$APKFILE" | awk '{print $1}')
echo "Built $APKFILE"
echo "Version: $APKVER"
echo "Size: $SIZE"
echo "SHA256sum: $SHA256"
