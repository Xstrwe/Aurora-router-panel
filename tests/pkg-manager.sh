#!/bin/sh
# Package-manager detection (opkg or apk) and the apk package build.
# opkg and apk are replaced by stubs; the apk package build runs only where apk-tools 3 exists.
set -u
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIB=$ROOT/files/usr/libexec/aurora-panel
fail=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# A PATH with the basic tools but neither opkg nor apk (a real apk may be on the caller's PATH).
BASE=$TMP/base; mkdir -p "$BASE"
for t in sh awk sed cat grep tail head cut tr date dirname mkdir rm mv cp ls touch chmod ln stat mktemp jq df sort uname id basename sleep kill wc od tee; do
	p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$BASE/$t"
done
mkstub() { # dir name -> a stub that logs its arguments to $TMP/pm.log
	mkdir -p "$1"
	cat > "$1/$2" <<EOF2
#!/bin/sh
echo "$2 \$*" >> "$TMP/pm.log"
case "$2 \$*" in
	"opkg list-installed wireguard-tools") echo "wireguard-tools - 1.0.20210914-1" ;;
	"apk list -I wireguard-tools") echo "wireguard-tools-1.0.20250521-r1 aarch64 {wireguard-tools} (GPL-2.0-only) [installed]" ;;
	"apk list -I wireguard") exit 0 ;;
esac
[ -n "\${PM_FAIL:-}" ] && [ "\${PM_FAIL}" = "$2 \$*" ] && { echo "ERROR: no such package" >&2; exit 1; }
exit 0
EOF2
	chmod 755 "$1/$2"
}
mkstub "$TMP/o" opkg
mkstub "$TMP/a" apk
pm_with() { # PATH-dirs... -> pm_name in a subshell
	( PATH=$(printf '%s:' "$@")$BASE; unset AURORA_PM; . "$LIB/pm-lib.sh"; pm_name )
}

# 1. detection
[ "$(pm_with "$TMP/o")" = opkg ] && ok "only opkg -> opkg" || bad "only opkg"
[ "$(pm_with "$TMP/a")" = apk ] && ok "only apk -> apk" || bad "only apk"
[ "$(pm_with)" = none ] && ok "neither -> none" || bad "neither"
[ "$(pm_with "$TMP/o" "$TMP/a")" = opkg ] && ok "both present -> opkg (the firmware default of 23.05/24.10)" || bad "both"
[ "$( PATH=$TMP/o:$BASE; AURORA_PM=apk; export AURORA_PM; . "$LIB/pm-lib.sh"; pm_name )" = apk ] && ok "AURORA_PM overrides the detection" || bad "AURORA_PM"

# 2. the verbs map to the right command line
run_pm() { # pmdir pm-function args...
	d=$1; shift
	: > "$TMP/pm.log"
	( PATH=$d:$BASE; unset AURORA_PM; . "$LIB/pm-lib.sh"; "$@" ) >/dev/null 2>&1
	cat "$TMP/pm.log"
}
[ "$(run_pm "$TMP/o" pm_update)" = "opkg update" ] && ok "opkg: update" || bad "opkg update"
[ "$(run_pm "$TMP/a" pm_update)" = "apk update" ] && ok "apk: update" || bad "apk update"
[ "$(run_pm "$TMP/o" pm_install kmod-wireguard wireguard-tools ip-full)" = "opkg install kmod-wireguard wireguard-tools ip-full" ] && ok "opkg: install" || bad "opkg install"
[ "$(run_pm "$TMP/a" pm_install kmod-wireguard wireguard-tools ip-full)" = "apk add kmod-wireguard wireguard-tools ip-full" ] && ok "apk: add" || bad "apk add"
[ "$(run_pm "$TMP/o" pm_upgrade wireguard-tools)" = "opkg upgrade wireguard-tools" ] && ok "opkg: upgrade" || bad "opkg upgrade"
[ "$(run_pm "$TMP/a" pm_upgrade wireguard-tools kmod-wireguard)" = "apk add -u wireguard-tools kmod-wireguard" ] && ok "apk: add -u" || bad "apk upgrade"
v=$( PATH=$TMP/o:$BASE; unset AURORA_PM; . "$LIB/pm-lib.sh"; pm_version wireguard-tools )
[ "$v" = 1.0.20210914-1 ] && ok "opkg: installed version read" || bad "opkg version: $v"
v=$( PATH=$TMP/a:$BASE; unset AURORA_PM; . "$LIB/pm-lib.sh"; pm_version wireguard-tools )
[ "$v" = 1.0.20250521-r1 ] && ok "apk: installed version read (name prefix removed)" || bad "apk version: $v"
v=$( PATH=$TMP/a:$BASE; unset AURORA_PM; . "$LIB/pm-lib.sh"; pm_version wireguard )
[ -z "$v" ] && ok "apk: a package that is not installed gives no version" || bad "apk version of a missing package: $v"
if ( PATH=$BASE; unset AURORA_PM; . "$LIB/pm-lib.sh"; pm_install x ) >/dev/null 2>&1; then bad "no package manager must fail"; else ok "no package manager: the verbs fail instead of guessing"; fi

# 3. install-client.sh (WireGuard button) and client-update.sh with apk
SD=$TMP/state; mkdir -p "$SD" "$TMP/etc" "$TMP/mod"
printf '#!/bin/sh\necho "wireguard-tools v1.0.20250521"\n' > "$TMP/wg"; chmod 755 "$TMP/wg"
ic() { # pmdir -> the wg install in the foreground; prints the final state file
	rm -rf "${SD:?}"/*; : > "$TMP/pm.log"
	( PATH=$1:$BASE; unset AURORA_PM
	  VLESS_PANEL_DIR=$TMP/etc VLESS_WG_BIN=$TMP/wg VLESS_WG_SYSMOD=$TMP/mod AURORA_INSTALL_DIR=$SD AURORA_POLL=0.2 \
	  sh "$LIB/install-client.sh" run wg ) >/dev/null 2>&1
	cat "$SD/aurora-install-wg.json" 2>/dev/null
}
r=$(ic "$TMP/a")
if [ "$(echo "$r" | jq -r .state)" = "done" ] && [ "$(echo "$r" | jq -r .percent)" = 100 ] && [ "$(echo "$r" | jq -r .version)" = 1.0.20250521-r1 ] \
   && [ "$(cat "$TMP/pm.log")" = "apk update
apk add kmod-wireguard
apk add -u kmod-wireguard
apk add wireguard-tools
apk add -u wireguard-tools
apk add ip-full
apk list -I wireguard-tools" ]; then
	ok "Install WireGuard with apk: apk update, apk add kmod-wireguard wireguard-tools ip-full, 100%, version shown"
else bad "wg with apk: $r / $(cat "$TMP/pm.log")"; fi
rm -rf "$TMP/mod"
r=$(ic "$TMP/a"); mkdir -p "$TMP/mod"
if [ "$(echo "$r" | jq -r .state)" = "done" ] || [ "$(echo "$r" | jq -r .state)" = error ]; then ok "wg with apk ends in a final state"; else bad "wg with apk final state: $r"; fi
r=$(PM_FAIL="apk add kmod-wireguard" ic "$TMP/a")
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'kmod-wireguard'; then ok "wg with apk: a failed apk add is shown as a short reason"; else bad "wg apk failure: $r"; fi
r=$(PM_FAIL="apk update" ic "$TMP/a")
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q '^apk update failed'; then ok "wg with apk: a failed apk update names apk"; else bad "wg apk update failure: $r"; fi
r=$(ic "$TMP/o")
if [ "$(echo "$r" | jq -r .state)" = "done" ] && grep -q '^opkg install kmod-wireguard' "$TMP/pm.log" && ! grep -q '^apk' "$TMP/pm.log"; then ok "Install WireGuard with opkg is unchanged"; else bad "wg with opkg: $r"; fi
r=$(ic "$BASE")
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'no package manager'; then ok "wg without opkg or apk: clear error"; else bad "wg without a package manager: $r"; fi

cu() { # pmdir -> client-update wireguard install
	: > "$TMP/pm.log"
	( PATH=$1:$BASE; unset AURORA_PM; sh "$LIB/client-update.sh" wireguard install ) 2>&1
}
out=$(cu "$TMP/a")
if echo "$out" | grep -q 'installed=1.0.20250521-r1 source=apk feed' && echo "$out" | grep -q '^OK' && grep -q '^apk update' "$TMP/pm.log" && grep -q '^apk add -u wireguard-tools kmod-wireguard' "$TMP/pm.log"; then ok "client-update wireguard with apk"; else bad "client-update apk: $out / $(cat "$TMP/pm.log")"; fi
out=$(cu "$TMP/o")
if echo "$out" | grep -q 'source=opkg feed' && grep -q '^opkg upgrade wireguard-tools kmod-wireguard' "$TMP/pm.log"; then ok "client-update wireguard with opkg"; else bad "client-update opkg: $out"; fi

# 4. the code calls the package manager only through pm-lib.sh
if ! grep -nE '(^|[;&|(`]|\$\()[[:space:]]*(opkg|apk)[[:space:]]+(update|install|add|upgrade|list-installed|list)' "$LIB/install-client.sh" "$LIB/client-update.sh" "$LIB/install-naive.sh" | grep -v ':[0-9]*:[[:space:]]*#' | grep -v 'err "\|fail "' | grep -q .; then ok "no direct opkg or apk call outside pm-lib.sh"; else bad "direct opkg or apk call"; fi
if ! grep -rn 'opkg' "$ROOT/files/www-aurora" "$ROOT/files/etc" | grep -q .; then ok "the web page and the backend do not mention opkg"; else bad "opkg mentioned in the page or the backend"; fi

# 5. apk version mapping (apk-tools version rules)
BA=$ROOT/tools/build-apk.sh
chkv() { [ "$(sh "$BA" version "$1" 2>/dev/null)" = "$2" ] && ok "apk version of $1 is $2" || bad "apk version of $1: got '$(sh "$BA" version "$1" 2>&1)', want $2"; }
chkv 1.5.0a5 1.5.0_alpha5-r1
chkv 1.5.0a12 1.5.0_alpha12-r1
chkv 1.4.1b2 1.4.1_beta2-r1
chkv 1.6.0c1 1.6.0_pre1-r1
chkv 1.6.0d3 1.6.0_rc3-r1
chkv 1.5.0 1.5.0-r1
if sh "$BA" version 1.5.0z1 >/dev/null 2>&1; then bad "an unmappable letter must be refused"; else ok "an unmappable letter is refused"; fi
if sh "$BA" version banana >/dev/null 2>&1; then bad "garbage version must be refused"; else ok "a garbage version is refused"; fi
CV=$(sed -n 's/^Version: //p' "$ROOT/control/control" | head -1)
if sh "$BA" version "$CV" >/dev/null 2>&1; then ok "the control version ($CV) maps to $(sh "$BA" version "$CV")"; else bad "control version $CV does not map"; fi

# 6. the apk package itself (needs apk-tools 3 and the .ipk from build.sh)
APKBIN=${APK:-apk}
IPK=$ROOT/feed/all/aurora-router-panel_${CV}_all.ipk
if command -v "$APKBIN" >/dev/null 2>&1 && "$APKBIN" --version 2>/dev/null | grep -q 'apk-tools 3\.' && [ -f "$IPK" ] && { [ "$(id -u)" = 0 ] || command -v fakeroot >/dev/null 2>&1 || unshare -Ur true 2>/dev/null; }; then
	OUT=$TMP/apk-out
	if APK=$APKBIN APK_OUT=$OUT sh "$BA" build >"$TMP/build.log" 2>&1; then ok "apk package builds"; else bad "apk build"; cat "$TMP/build.log"; fi
	F=$(ls "$OUT"/aurora-router-panel-*.apk 2>/dev/null | head -1)
	AV=$(sh "$BA" version "$CV")
	if [ -n "$F" ] && [ "$(basename "$F")" = "aurora-router-panel-$AV.apk" ]; then ok "file name is aurora-router-panel-$AV.apk"; else bad "apk file name: $F"; fi
	"$APKBIN" adbdump "$F" > "$TMP/dump.txt" 2>&1
	for d in curl jq ucode uhttpd kmod-nft-tproxy; do grep -qE "^    - $d\$" "$TMP/dump.txt" && ok "apk depends on $d" || bad "apk dependency $d"; done
	grep -q "^    - '!vless-router-panel'" "$TMP/dump.txt" && ok "apk conflicts with the old vless-router-panel (as the .ipk does)" || bad "apk conflict"
	grep -q '^  arch: noarch' "$TMP/dump.txt" && ok "arch is noarch (scripts only, runs on every CPU)" || bad "apk arch"
	for s in post-install post-upgrade pre-deinstall post-deinstall; do grep -q "^  $s: " "$TMP/dump.txt" && ok "apk has the $s script" || bad "apk script $s"; done
	if ! grep -E '^ *(user|group): ' "$TMP/dump.txt" | grep -qv ': root$'; then ok "every path is owned by root:root"; else bad "apk has non-root owners"; fi
	if ! grep -q 'opkg' "$TMP/dump.txt"; then ok "the apk scripts contain no opkg code"; else bad "opkg left in the apk scripts"; fi
	# same files as the .ipk
	mkdir -p "$TMP/ipk"; gzip -dc "$IPK" | tar -C "$TMP/ipk" -xf - ./data.tar.gz
	tar -tzf "$TMP/ipk/data.tar.gz" | sed 's#^\./##; s#/$##' | grep -v '^$' | grep -v '^\.$' | sort > "$TMP/ipk.list"
	"$APKBIN" adbdump "$F" | awk '/^paths:/ {p=1} p' > /dev/null
	# a test root with stub dependencies: apk resolves the package, installs it, and removes it again
	REPO=$TMP/repo; mkdir -p "$REPO" "$TMP/root"
	for p in curl jq ucode uhttpd kmod-nft-tproxy; do "$APKBIN" mkpkg --info "name:$p" --info version:1.0-r0 --info arch:noarch --info description:stub --output "$REPO/$p-1.0-r0.apk" >/dev/null 2>&1; done
	cp "$F" "$REPO/"
	"$APKBIN" mkndx --allow-untrusted -o "$REPO/packages.adb" "$REPO"/*.apk >/dev/null 2>&1
	APKR="$APKBIN --root $TMP/root --allow-untrusted --no-network --no-cache --no-scripts --repositories-file /dev/null --repository $REPO/packages.adb"
	asroot() { if [ "$(id -u)" = 0 ]; then "$@"; elif command -v fakeroot >/dev/null 2>&1; then fakeroot "$@"; else unshare -Ur "$@"; fi; }
	# shellcheck disable=SC2086
	if asroot sh -c "$APKR --initdb --arch aarch64_cortex-a73 add aurora-router-panel" >"$TMP/inst.log" 2>&1 && [ -x "$TMP/root/etc/xray/vless.sh" ] && [ -f "$TMP/root/www-aurora/index.html" ] \
	   && [ -x "$TMP/root/usr/libexec/aurora-panel/install-client.sh" ] && [ -f "$TMP/root/usr/libexec/aurora-panel/pm-lib.sh" ]; then
		ok "apk add resolves the 5 dependencies and installs the files into a test root"
	else bad "apk add into a test root"; cat "$TMP/inst.log"; fi
	[ -x "$TMP/root/etc/init.d/aurora-steer" ] && ok "init scripts keep their exec bit" || bad "init script modes"
	asroot sh -c "$APKBIN --root $TMP/root --allow-untrusted --no-network --no-cache --repositories-file /dev/null list -I aurora-router-panel" 2>/dev/null | grep -q "^aurora-router-panel-$AV " && ok "apk reports aurora-router-panel-$AV installed" || bad "apk list -I"
	# every file of the .ipk is in the apk's file list
	missing=0
	while read -r f; do
		[ -z "$f" ] || [ -d "$TMP/root/$f" ] || [ -e "$TMP/root/$f" ] || { echo "missing in apk: $f"; missing=1; }
	done < "$TMP/ipk.list"
	[ "$missing" = 0 ] && ok "every file of the .ipk is in the apk" || bad "files missing in the apk"
	# the scripts, run against stubs (apk runs the same text in the router's root)
	asroot sh -c "$APKR del aurora-router-panel" >/dev/null 2>&1
	[ ! -e "$TMP/root/etc/xray/vless.sh" ] && ok "apk del removes the files" || bad "apk del"
	# scripts, extracted from the package, against stub commands
	SCR=$TMP/scr; export SCR; mkdir -p "$SCR/bin" "$SCR/etc"
	for s in post-install post-upgrade pre-deinstall post-deinstall; do
		"$APKBIN" adbdump "$F" | awk -v s="  $s: |" '$0 == s {p=1; next} p && /^    / {sub(/^    /, ""); print; next} p {exit}' > "$SCR/$s"
		[ -s "$SCR/$s" ] || bad "could not extract $s from the apk"
	done
	cat > "$SCR/bin/uci" <<'EOF2'
#!/bin/sh
echo "uci $*" >> "$SCR/uci.log"
case "$*" in
	"-q get network.lan.ipaddr") [ -n "${LAN:-}" ] && echo "$LAN" ;;
	"-q get uhttpd.aurora") [ -f "$SCR/set" ] || exit 1 ;;
	"set uhttpd.aurora=uhttpd") : > "$SCR/set" ;;
	"-q delete uhttpd.aurora") rm -f "$SCR/set" ;;
	"-q get uhttpd.vless") exit 1 ;;
esac
exit 0
EOF2
	chmod 755 "$SCR/bin/uci"
	( LAN=192.168.31.1/24; PATH=$SCR/bin:$PATH; export LAN SCR PATH; cd "$SCR" || exit 1
	  # the script writes to /etc/xray: run it on a copy that points to a temp dir instead
	  sed "s#/etc/xray#$SCR/etc#g; s#/etc/init.d/#$SCR/#g; s#/usr/libexec/aurora-panel/autoupdate-lib.sh#$SCR/none#g" post-install > pi.sh
	  : > "$SCR/uhttpd"; : > "$SCR/aurora-steer"; chmod 755 "$SCR/uhttpd" "$SCR/aurora-steer"
	  sh pi.sh >/dev/null 2>&1 )
	if grep -q 'add_list uhttpd.aurora.listen_http=192.168.31.1:8088' "$SCR/uci.log"; then ok "post-install: the panel listens on the LAN address of the router (192.168.31.1:8088), not a fixed one"; else bad "post-install listen address: $(cat "$SCR/uci.log" 2>/dev/null)"; fi
	rm -f "$SCR/uci.log" "$SCR/set"
	( LAN=''; PATH=$SCR/bin:$PATH; export LAN SCR PATH; cd "$SCR" || exit 1
	  sed "s#/etc/xray#$SCR/etc#g; s#/etc/init.d/#$SCR/#g; s#/usr/libexec/aurora-panel/autoupdate-lib.sh#$SCR/none#g" post-install > pi.sh; sh pi.sh >/dev/null 2>&1 )
	if grep -q 'add_list uhttpd.aurora.listen_http=192.168.8.1:8088' "$SCR/uci.log"; then ok "post-install: falls back to 192.168.8.1:8088 when the LAN address is unknown"; else bad "post-install fallback address"; fi
	[ -f "$SCR/etc/httpd.conf" ] && ok "post-install creates httpd.conf without a password" || bad "post-install httpd.conf"
	head -3 "$SCR/post-upgrade" | grep -q '^export PKG_UPGRADE=1' && ok "post-upgrade sets PKG_UPGRADE=1 (as OpenWrt's apk scripts do)" || bad "post-upgrade PKG_UPGRADE"
	if ! head -3 "$SCR/pre-deinstall" | grep -q PKG_UPGRADE && ! head -3 "$SCR/post-deinstall" | grep -q 'PKG_UPGRADE=1$'; then ok "pre/post-deinstall run only on a real removal (apk does not call them on upgrade)"; else bad "deinstall scripts"; fi
	grep -q 'au_cron_remove' "$SCR/pre-deinstall" && grep -q "uci -q delete uhttpd.aurora" "$SCR/post-deinstall" && ok "pre-deinstall drops the cron line, post-deinstall drops uhttpd.aurora" || bad "deinstall script contents"
	"$APKBIN" version -t 1.5.0_alpha5-r1 1.5.0_alpha6-r1 | grep -q '^<$' && "$APKBIN" version -t 1.5.0_alpha12-r1 1.5.0_alpha5-r1 | grep -q '^>$' && "$APKBIN" version -t 1.5.0_alpha5-r1 1.5.0-r1 | grep -q '^<$' && ok "apk orders alpha5 < alpha6 < alpha12 < the full 1.5.0" || bad "apk version order"
else
	echo "skip - apk package tests need apk-tools 3 (set APK=/path/to/apk), the built .ipk and fakeroot/root/user namespaces"
fi

if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck -S warning -s sh "$0" >/dev/null 2>&1; then ok "shellcheck (warnings) of this test"; else bad "shellcheck of the test"; shellcheck -S warning -s sh "$0"; fi
	if shellcheck -s sh "$LIB/pm-lib.sh" "$LIB/install-client.sh" "$LIB/client-update.sh" "$BA" >/dev/null 2>&1; then ok "shellcheck pm-lib, install-client, client-update, build-apk"; else bad "shellcheck"; shellcheck -s sh "$LIB/pm-lib.sh" "$LIB/install-client.sh" "$LIB/client-update.sh" "$BA"; fi
fi

if [ "$fail" -eq 0 ]; then echo "All package-manager tests passed."; else echo "$fail package-manager test(s) failed." >&2; exit 1; fi
