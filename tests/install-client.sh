#!/bin/sh
# install-client.sh: the four Install buttons' backend (xray, hy2, naive, wg).
# GitHub and opkg are replaced by local files and stubs; nothing touches the network.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IC=$ROOT/files/usr/libexec/aurora-panel/install-client.sh
VS=$ROOT/files/etc/xray/vless.sh
fail=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN=$TMP/bin; GH=$TMP/gh; SD=$TMP/state; INS=$TMP/usr; ASSET=$TMP/share
mkdir -p "$BIN" "$GH/api" "$GH/dl" "$SD" "$INS" "$ASSET" "$TMP/etc"
REAL_PATH=$PATH
cat > "$BIN/uname" <<'EOF2'
#!/bin/sh
[ "$1" = -m ] && { echo aarch64; exit 0; }
exec /bin/uname "$@"
EOF2
cat > "$BIN/pidof" <<'EOF2'
#!/bin/sh
for p in ${PIDOF_UP:-}; do [ "$p" = "$1" ] && { echo 4242; exit 0; }; done
exit 1
EOF2
cat > "$BIN/vless-sh" <<EOF2
#!/bin/sh
echo "\$*" >> "$TMP/vsh.log"
[ "\${VSH_FAIL:-0}" = 1 ] && [ ! -e "$TMP/vsh.failed" ] && { : > "$TMP/vsh.failed"; exit 1; }
exit 0
EOF2
cat > "$BIN/opkg" <<EOF2
#!/bin/sh
echo "\$*" >> "$TMP/opkg.log"
[ "\${OPKG_FAIL:-}" = "\$1 \$2" ] && { echo "Collected errors: no such package" >&2; exit 1; }
case "\$1" in list-installed) echo "wireguard-tools - 1.0.20210914-1";; esac
exit 0
EOF2
chmod 755 "$BIN"/*
PATH=$BIN:$PATH

sha() { sha256sum "$1" | cut -d' ' -f1; }
export VLESS_PANEL_DIR=$TMP/etc VLESS_AU_VLESS_SH=$BIN/vless-sh
export VLESS_XRAY_BIN=$INS/xray VLESS_HYSTERIA_BIN=$INS/hysteria VLESS_NAIVE_BIN=$INS/naive VLESS_XRAY_ASSET=$ASSET
export VLESS_WG_BIN=$INS/wg VLESS_WG_SYSMOD=$TMP/sysmod
export AURORA_POLL=0.2 AURORA_GH_API=file://$GH/api AURORA_GH_DL=file://$GH/dl AURORA_INSTALL_DIR=$SD

# ---- fixtures ----
mkdir -p "$GH/api/repos/XTLS/Xray-core/releases" "$GH/dl/XTLS/Xray-core/releases/download/v9.9.9"
mkdir -p "$GH/api/repos/apernet/hysteria/releases" "$GH/dl/apernet/hysteria/releases/download/app/v2.9.9"
mkdir -p "$GH/api/repos/klzgrad/naiveproxy/releases" "$GH/dl/klzgrad/naiveproxy/releases/download/v1.2.3-4"
printf '{"tag_name":"v9.9.9"}' > "$GH/api/repos/XTLS/Xray-core/releases/latest"
printf '{"tag_name":"app/v2.9.9"}' > "$GH/api/repos/apernet/hysteria/releases/latest"
X=$TMP/fx; mkdir -p "$X"
printf '#!/bin/sh\n[ "$1" = version ] && echo "Xray 9.9.9 (test) Custom"\nexit 0\n' > "$X/xray"
printf 'GEOIP-NEW' > "$X/geoip.dat"; printf 'GEOSITE-NEW' > "$X/geosite.dat"
python3 - "$X" "$GH/dl/XTLS/Xray-core/releases/download/v9.9.9/Xray-linux-arm64-v8a.zip" <<'PY'
import sys, zipfile
x, out = sys.argv[1:3]
z = zipfile.ZipFile(out, 'w')
for n in ('xray', 'geoip.dat', 'geosite.dat'):
    zi = zipfile.ZipInfo(n); zi.external_attr = 0o755 << 16
    z.writestr(zi, open(x + '/' + n, 'rb').read())
z.close()
PY
XZ=$GH/dl/XTLS/Xray-core/releases/download/v9.9.9/Xray-linux-arm64-v8a.zip
printf 'MD5= 00\nSHA2-256= %s\nSHA2-512= 00\n' "$(sha "$XZ")" > "$XZ.dgst"
printf '#!/bin/sh\n[ "$1" = version ] && printf "Version:\\tv2.9.9\\nBuildDate: x\\n"\nexit 0\n' > "$TMP/hy"
HF=$GH/dl/apernet/hysteria/releases/download/app/v2.9.9
cp "$TMP/hy" "$HF/hysteria-linux-arm64"
printf '%s  build/hysteria-linux-arm64\n%s  build/hysteria-linux-amd64\n' "$(sha "$TMP/hy")" 00 > "$HF/hashes.txt"
mkdir -p "$TMP/nv/naiveproxy-v1.2.3-4-openwrt-aarch64_cortex-a53-static"
printf '#!/bin/sh\n[ "$1" = --version ] && echo "naive 1.2.3.4-4"\nexit 0\n' > "$TMP/nv/naiveproxy-v1.2.3-4-openwrt-aarch64_cortex-a53-static/naive"
printf '{"x":1}' > "$TMP/nv/naiveproxy-v1.2.3-4-openwrt-aarch64_cortex-a53-static/config.json"
chmod 755 "$TMP/nv"/*/naive
NF=naiveproxy-v1.2.3-4-openwrt-aarch64_cortex-a53-static.tar.xz
NDL=$GH/dl/klzgrad/naiveproxy/releases/download/v1.2.3-4
( cd "$TMP/nv" && tar -c naiveproxy-v1.2.3-4-openwrt-aarch64_cortex-a53-static | xz -c ) > "$NDL/$NF"
naive_api() { # digest
	printf '{"tag_name":"v1.2.3-4","assets":[{"name":"%s","digest":"%s"}]}' "$NF" "$1" > "$GH/api/repos/klzgrad/naiveproxy/releases/latest"
}
naive_api "sha256:$(sha "$NDL/$NF")"

# run: start an install, wait for it to end, print the final JSON
run() { # proto
	out=$("$IC" start "$1")
	case "$out" in OK*) ;; *) echo "$out"; return 1;; esac
	i=0
	while [ $i -lt 60 ]; do
		st=$(jq -r .state "$SD/aurora-install-$1.json" 2>/dev/null)
		[ "$st" = done ] || [ "$st" = error ] && break
		sleep 0.5; i=$((i+1))
	done
	cat "$SD/aurora-install-$1.json"
}
reset() { rm -rf "$INS"/* "$ASSET"/* "$SD"/* "$TMP/vsh.log" "$TMP/vsh.failed" "$TMP/opkg.log" "$TMP/sysmod"; unset PIDOF_UP VSH_FAIL OPKG_FAIL AURORA_SOCKS_FORCE; : > "$TMP/etc/proto"; }

# 1. xray: installs xray + geoip.dat + geosite.dat, shows 100% and the version, touches no service
reset
r=$(run xray)
if [ "$(echo "$r" | jq -r .state)" = done ] && [ "$(echo "$r" | jq -r .percent)" = 100 ] && [ "$(echo "$r" | jq -r .version)" = 9.9.9 ] \
   && [ -x "$INS/xray" ] && [ "$(cat "$ASSET/geoip.dat")" = GEOIP-NEW ] && [ "$(cat "$ASSET/geosite.dat")" = GEOSITE-NEW ] \
   && [ ! -e "$TMP/vsh.log" ] && [ ! -e "$SD/aurora-install.lock" ]; then
	ok "xray: official zip installed with geoip/geosite, 100%, version reported, no service touched"
else bad "xray install: $r"; fi
s=$("$IC" status xray)
if [ "$(echo "$s" | jq -r .installed)" = true ] && [ "$(echo "$s" | jq -r .version)" = 9.9.9 ]; then ok "status reports installed + version"; else bad "status: $s"; fi
s=$("$IC" status hy2)
if [ "$(echo "$s" | jq -r .installed)" = false ] && [ "$(echo "$s" | jq -r .state)" = idle ]; then ok "status reports a missing client as not installed"; else bad "status hy2: $s"; fi
if "$IC" status | jq -e '.xray.installed == true and .hy2.installed == false and .naive.installed == false and .wg.installed == false' >/dev/null; then ok "status without an argument lists all four clients"; else bad "status all"; fi

# 2. xray reinstall while running: only xray is restarted
reset; mkdir -p "$ASSET"; printf '#!/bin/sh\necho old\n' > "$INS/xray"; chmod 755 "$INS/xray"
PIDOF_UP=xray; export PIDOF_UP
r=$(run xray)
if [ "$(echo "$r" | jq -r .state)" = done ] && [ "$(cat "$TMP/vsh.log")" = "restart-svc xray" ]; then ok "a running Xray is restarted once, no other service is touched"; else bad "xray restart: $r / $(cat "$TMP/vsh.log" 2>/dev/null)"; fi

# 3. restart failure: the old binary and data are put back
reset; printf '#!/bin/sh\necho old\n' > "$INS/xray"; chmod 755 "$INS/xray"; printf OLDGEO > "$ASSET/geoip.dat"
PIDOF_UP=xray; VSH_FAIL=1; export PIDOF_UP VSH_FAIL
r=$(run xray)
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'old one was put back' \
   && grep -q old "$INS/xray" && [ "$(cat "$ASSET/geoip.dat")" = OLDGEO ] && [ "$(wc -l < "$TMP/vsh.log")" = 2 ]; then
	ok "a failed restart puts the old Xray and data files back and restarts it"
else bad "rollback: $r"; fi

# 4. checksum mismatch: nothing is replaced
reset; printf '#!/bin/sh\necho old\n' > "$INS/xray"; chmod 755 "$INS/xray"
cp "$XZ.dgst" "$TMP/dgst.good"; printf 'SHA2-256= %s\n' 0000 > "$XZ.dgst"
r=$(run xray)
cp "$TMP/dgst.good" "$XZ.dgst"
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'checksum mismatch' && grep -q old "$INS/xray" && [ ! -e "$ASSET/geoip.dat" ]; then
	ok "xray: a wrong checksum stops the install and changes nothing"
else bad "xray checksum: $r"; fi

# 5. hysteria 2
reset
r=$(run hy2)
if [ "$(echo "$r" | jq -r .state)" = done ] && [ "$(echo "$r" | jq -r .version)" = 2.9.9 ] && [ -x "$INS/hysteria" ]; then ok "hy2: official release installed and checked against hashes.txt"; else bad "hy2: $r"; fi
reset; cp "$HF/hashes.txt" "$TMP/hashes.good"; sed -i 's/^[0-9a-f]\{64\}  build\/hysteria-linux-arm64/aaaa  build\/hysteria-linux-arm64/' "$HF/hashes.txt"
r=$(run hy2); cp "$TMP/hashes.good" "$HF/hashes.txt"
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'checksum mismatch' && [ ! -e "$INS/hysteria" ]; then ok "hy2: a wrong checksum is refused"; else bad "hy2 checksum: $r"; fi
reset; printf '#!/bin/sh\necho old\n' > "$INS/hysteria"; chmod 755 "$INS/hysteria"; PIDOF_UP="hysteria xray naive"; export PIDOF_UP
r=$(run hy2)
if [ "$(cat "$TMP/vsh.log")" = "restart-svc hysteria" ]; then ok "hy2: only the hysteria service is restarted while others keep running"; else bad "hy2 restart: $(cat "$TMP/vsh.log")"; fi

# 6. naive
reset
r=$(run naive)
if [ "$(echo "$r" | jq -r .state)" = done ] && [ "$(echo "$r" | jq -r .version)" = 1.2.3.4-4 ] && [ -x "$INS/naive" ] && [ ! -e "$TMP/etc/naive/config.json" ]; then ok "naive: release installed through install-naive.sh, GitHub digest checked, no config written"; else bad "naive: $r"; fi
reset; naive_api "sha256:0000"
r=$(run naive)
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'checksum mismatch' && [ ! -e "$INS/naive" ]; then ok "naive: a wrong digest is refused"; else bad "naive digest: $r"; fi
naive_api "sha256:$(sha "$NDL/$NF")"

# 7. wireguard through opkg, step by step, no service touched
reset
r=$(run wg)
cat > "$TMP/mkwg" <<EOF2
EOF2
if [ "$(echo "$r" | jq -r .state)" = error ]; then
	if echo "$r" | jq -r .error | grep -q 'kernel module is not available'; then ok "wg: packages installed, a missing kernel module is reported clearly"; else bad "wg (no module): $r"; fi
else bad "wg should fail without a module: $r"; fi
reset; mkdir -p "$TMP/sysmod"; printf '#!/bin/sh\nexit 0\n' > "$INS/wg"; chmod 755 "$INS/wg"
rm -f "$TMP/opkg.log"
r=$(run wg)
if [ "$(echo "$r" | jq -r .state)" = done ] && grep -q '^update' "$TMP/opkg.log" && grep -q '^install kmod-wireguard' "$TMP/opkg.log" \
   && grep -q '^install wireguard-tools' "$TMP/opkg.log" && grep -q '^install ip-full' "$TMP/opkg.log" && [ ! -e "$TMP/vsh.log" ]; then
	ok "wg: opkg update, kmod-wireguard, wireguard-tools, ip-full, no service touched"
else bad "wg: $r / $(cat "$TMP/opkg.log")"; fi
reset; mkdir -p "$TMP/sysmod"; OPKG_FAIL="install kmod-wireguard"; export OPKG_FAIL
r=$(run wg)
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'kmod-wireguard'; then ok "wg: an opkg failure is shown as a short reason"; else bad "wg opkg failure: $r"; fi

# 8. free space is checked before downloading
reset
cat > "$BIN/df" <<'EOF2'
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "x 100 90 10 90% /"
EOF2
chmod 755 "$BIN/df"
r=$(run xray)
rm -f "$BIN/df"
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'not enough free space' && [ ! -e "$INS/xray" ]; then ok "low free space stops the install before any download"; else bad "space: $r"; fi

# 9. only one install at a time
reset
mkdir "$SD/aurora-install.lock"; echo "$$" > "$SD/aurora-install.lock/pid"; echo hy2 > "$SD/aurora-install.lock/proto"
out=$("$IC" start xray)
rm -rf "$SD/aurora-install.lock"
if echo "$out" | grep -q 'ERROR: another installation is running (hy2)'; then ok "a second install is refused while one is running"; else bad "lock: $out"; fi
mkdir "$SD/aurora-install.lock"; echo 999999 > "$SD/aurora-install.lock/pid"
out=$("$IC" start xray)
if echo "$out" | grep -q '^OK'; then ok "a stale lock from a dead process is cleared"; else bad "stale lock: $out"; fi
i=0; while [ $i -lt 40 ] && [ -e "$SD/aurora-install.lock" ]; do sleep 0.5; i=$((i+1)); done
if "$IC" start bogus | grep -q usage; then ok "an unknown client is refused"; else bad "bogus"; fi

# 10. a dead installer is shown as interrupted, not as running forever
reset
printf '{"state":"running","percent":40,"stage":"downloading"}' > "$SD/aurora-install-hy2.json"
s=$("$IC" status hy2)
if [ "$(echo "$s" | jq -r .state)" = error ] && echo "$s" | jq -r .error | grep -q interrupted; then ok "an install that died is reported as interrupted"; else bad "interrupted: $s"; fi

# 11. progress is real: a slow download shows a percent between the download bounds
reset
REALCURL=$(command -v curl)
cat > "$BIN/curl" <<EOF2
#!/bin/sh
case "\$*" in
  *Xray-linux-arm64-v8a.zip) printf '\\r######              50.0%%' >&2; sleep 4; printf '\\r################## 100.0%%' >&2;;
esac
exec "$REALCURL" "\$@"
EOF2
chmod 755 "$BIN/curl"
"$IC" start xray >/dev/null
seen=""
i=0
while [ $i -lt 40 ]; do
	p=$(jq -r 'select(.state=="running" and .stage=="downloading") | .percent' "$SD/aurora-install-xray.json" 2>/dev/null)
	[ -n "$p" ] && [ "$p" -gt 10 ] && [ "$p" -lt 62 ] && { seen=$p; break; }
	sleep 0.25; i=$((i+1))
done
sleep 6
rm -f "$BIN/curl"
if [ -n "$seen" ] && [ "$(jq -r .state "$SD/aurora-install-xray.json")" = done ]; then ok "progress follows the download (saw ${seen}% while downloading, then 100%)"; else bad "progress: seen=$seen $(cat "$SD/aurora-install-xray.json")"; fi

# 12. GitHub blocked directly: the download goes through the active tunnel's local SOCKS entry
reset
echo vless > "$TMP/etc/proto"
cat > "$BIN/curl" <<EOF2
#!/bin/sh
echo "\$*" >> "$TMP/curl.log"
case "\$*" in *--socks5-hostname*) ;; *) exit 7;; esac
a=""; skip=0
for x in "\$@"; do
  if [ \$skip = 1 ]; then skip=0; continue; fi
  case "\$x" in --socks5-hostname) skip=1; continue;; esac
  a="\$a \$x"
done
exec "$REALCURL" \$a
EOF2
chmod 755 "$BIN/curl"; rm -f "$TMP/curl.log"
AURORA_SOCKS_FORCE=127.0.0.1:10808; export AURORA_SOCKS_FORCE
r=$(run xray)
rm -f "$BIN/curl"; unset AURORA_SOCKS_FORCE
if [ "$(echo "$r" | jq -r .state)" = done ] && grep -q -- '--socks5-hostname 127.0.0.1:10808' "$TMP/curl.log" && grep -q -v -- '--socks5-hostname' "$TMP/curl.log"; then ok "download falls back from the direct path to the active protocol's SOCKS entry"; else bad "socks fallback: $r"; fi
reset
cat > "$BIN/curl" <<EOF2
#!/bin/sh
exit 7
EOF2
chmod 755 "$BIN/curl"
r=$(run xray); rm -f "$BIN/curl"
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'could not download'; then ok "when GitHub is unreachable the error says so"; else bad "unreachable: $r"; fi

# 13. vless.sh front end
reset
out=$(VLESS_INSTALL_CLIENT=$IC sh "$VS" install hy2)
i=0; while [ $i -lt 40 ] && [ ! -x "$INS/hysteria" ]; do sleep 0.5; i=$((i+1)); done; sleep 1
if echo "$out" | grep -q '^OK' && [ -x "$INS/hysteria" ] && VLESS_INSTALL_CLIENT=$IC sh "$VS" install-status hy2 | jq -e '.state=="done"' >/dev/null; then ok "vless.sh install <p> and install-status work"; else bad "vless.sh install: $out"; fi

# 14. nothing runs at package install time
if ! grep -q 'install-client\|install-naive' "$ROOT/control/postinst" "$ROOT/control/prerm" "$ROOT/control/postrm"; then ok "the package scripts never run the installer (button-driven only)"; else bad "package scripts call the installer"; fi

# 15. no pipe-to-shell, only official hosts
if ! grep -q 'curl.*|.*sh' "$IC" && ! grep -n 'https\?://' "$IC" "$ROOT/files/usr/libexec/aurora-panel/install-lib.sh" | grep -v 'github.com\|^.*:#' | grep -q .; then ok "the installer downloads only from the developers' GitHub releases"; else bad "unexpected URLs in install-client"; fi

if command -v shellcheck >/dev/null 2>&1; then
	if shellcheck -s sh "$IC" "$ROOT/files/usr/libexec/aurora-panel/install-lib.sh" "$ROOT/files/usr/libexec/aurora-panel/install-naive.sh" >/dev/null 2>&1; then ok "shellcheck install-client, install-lib, install-naive"; else bad "shellcheck"; shellcheck -s sh "$IC" "$ROOT/files/usr/libexec/aurora-panel/install-lib.sh" "$ROOT/files/usr/libexec/aurora-panel/install-naive.sh"; fi
fi

if [ "$fail" -eq 0 ]; then echo "All install-client tests passed."; else echo "$fail install-client test(s) failed." >&2; exit 1; fi
