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
export VLESS_DNSPROXY_BIN=$INS/dnsproxy VLESS_WG_BIN=$INS/wg VLESS_WG_SYSMOD=$TMP/sysmod
export AURORA_POLL=0.2 AURORA_GH_API=file://$GH/api AURORA_GH_DL=file://$GH/dl AURORA_INSTALL_DIR=$SD

# ---- fixtures ----
mkdir -p "$GH/api/repos/XTLS/Xray-core/releases" "$GH/dl/XTLS/Xray-core/releases/download/v9.9.9"
mkdir -p "$GH/api/repos/apernet/hysteria/releases" "$GH/dl/apernet/hysteria/releases/download/app/v2.9.9"
mkdir -p "$GH/api/repos/AdguardTeam/dnsproxy/releases" "$GH/dl/AdguardTeam/dnsproxy/releases/download/v0.99.0"
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
# dnsproxy (AdguardTeam): linux-arm64 tarball with a linux-arm64/ directory, digest in the release JSON
DF=dnsproxy-linux-arm64-v0.99.0.tar.gz
DDL=$GH/dl/AdguardTeam/dnsproxy/releases/download/v0.99.0
mkdir -p "$TMP/dpx/linux-arm64"
printf '#!/bin/sh\n[ "$1" = --version ] && echo "dnsproxy v0.99.0"\nexit 0\n' > "$TMP/dpx/linux-arm64/dnsproxy"
printf 'LICENSE' > "$TMP/dpx/linux-arm64/LICENSE"
chmod 755 "$TMP/dpx/linux-arm64/dnsproxy"
( cd "$TMP/dpx" && tar -cz linux-arm64 ) > "$DDL/$DF"
dns_api() { # digest-or-empty
	if [ -n "$1" ]; then printf '{"tag_name":"v0.99.0","assets":[{"name":"%s","digest":"%s"}]}' "$DF" "$1"
	else printf '{"tag_name":"v0.99.0","assets":[{"name":"%s"}]}' "$DF"; fi > "$GH/api/repos/AdguardTeam/dnsproxy/releases/latest"
}
dns_api "sha256:$(sha "$DDL/$DF")"

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

# 6. naive: Naive + dnsproxy are one install
reset
r=$(run naive)
if [ "$(echo "$r" | jq -r .state)" = done ] && [ "$(echo "$r" | jq -r .percent)" = 100 ] && [ "$(echo "$r" | jq -r .version)" = 1.2.3.4-4 ] \
   && [ -x "$INS/naive" ] && [ -x "$INS/dnsproxy" ] && [ ! -e "$TMP/etc/naive/config.json" ] && [ ! -e "$TMP/vsh.log" ]; then
	ok "naive: Naive and dnsproxy installed together, checksums checked, no config written, no service touched"
else bad "naive: $r"; fi
s=$("$IC" status naive)
if [ "$(echo "$s" | jq -r .installed)" = true ] && [ "$(echo "$s" | jq -r .version)" = 1.2.3.4-4 ] && [ "$(echo "$s" | jq -r .dnsproxy_version)" = 0.99.0 ] && [ "$(echo "$s" | jq -r .missing)" = "" ]; then
	ok "naive status shows both versions (naive and dnsproxy)"
else bad "naive status: $s"; fi
# only one of the two present: not installed, the missing one is named
rm -f "$INS/dnsproxy"
s=$("$IC" status naive)
if [ "$(echo "$s" | jq -r .installed)" = false ] && [ "$(echo "$s" | jq -r .missing)" = dnsproxy ]; then ok "naive without dnsproxy is reported as not fully installed (dnsproxy missing)"; else bad "naive missing dnsproxy: $s"; fi
if "$IC" status | jq -e '.naive.installed == false' >/dev/null; then ok "status of all clients agrees"; else bad "status all naive"; fi
# the button on a half install adds dnsproxy
r=$(run naive)
if [ "$(echo "$r" | jq -r .state)" = done ] && [ -x "$INS/dnsproxy" ] && [ "$("$IC" status naive | jq -r .installed)" = true ]; then ok "pressing Install Naive on a half install completes it"; else bad "naive repair: $r"; fi
# wrong naive digest: nothing is installed, dnsproxy is not installed either
reset; naive_api "sha256:0000"
r=$(run naive)
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'checksum mismatch' && [ ! -e "$INS/naive" ] && [ ! -e "$INS/dnsproxy" ]; then ok "naive: a wrong digest is refused, nothing installed"; else bad "naive digest: $r"; fi
naive_api "sha256:$(sha "$NDL/$NF")"
# wrong dnsproxy digest: neither binary is replaced (old Naive stays)
reset; printf '#!/bin/sh\necho old\n' > "$INS/naive"; chmod 755 "$INS/naive"
dns_api "sha256:0000"
r=$(run naive)
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'dnsproxy download is damaged' && grep -q old "$INS/naive" && [ ! -e "$INS/dnsproxy" ]; then
	ok "dnsproxy: a wrong digest is refused and the existing Naive is left untouched"
else bad "dnsproxy digest: $r"; fi
# no digest in the release JSON: checksums.txt is used, and a wrong one is refused
reset; dns_api ""
printf '%s  %s\n' "$(sha "$DDL/$DF")" "$DF" > "$DDL/checksums.txt"
r=$(run naive)
if [ "$(echo "$r" | jq -r .state)" = done ] && [ -x "$INS/dnsproxy" ]; then ok "dnsproxy: checksums.txt is used when the release has no digest"; else bad "dnsproxy checksums.txt: $r"; fi
reset; printf '%s  %s\n' 0000 "$DF" > "$DDL/checksums.txt"
r=$(run naive)
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'checksum mismatch' && [ ! -e "$INS/naive" ]; then ok "dnsproxy: a wrong checksums.txt entry is refused"; else bad "dnsproxy checksums.txt bad: $r"; fi
reset; rm -f "$DDL/checksums.txt"
r=$(run naive)
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'no checksum is published' && [ ! -e "$INS/naive" ]; then ok "dnsproxy: no published checksum at all is refused"; else bad "dnsproxy no checksum: $r"; fi
dns_api "sha256:$(sha "$DDL/$DF")"
# a running Naive service (or only its dnsproxy) is restarted once, with both binaries replaced
reset; printf '#!/bin/sh\necho old\n' > "$INS/naive"; printf '#!/bin/sh\necho old\n' > "$INS/dnsproxy"; chmod 755 "$INS/naive" "$INS/dnsproxy"
PIDOF_UP="naive xray hysteria"; export PIDOF_UP
r=$(run naive)
if [ "$(echo "$r" | jq -r .state)" = done ] && [ "$(cat "$TMP/vsh.log")" = "restart-svc naive" ] && [ "$("$IC" status naive | jq -r .dnsproxy_version)" = 0.99.0 ]; then ok "naive: a running service is restarted once with both new binaries; other services untouched"; else bad "naive restart: $r / $(cat "$TMP/vsh.log" 2>/dev/null)"; fi
reset; printf '#!/bin/sh\necho old\n' > "$INS/dnsproxy"; chmod 755 "$INS/dnsproxy"; PIDOF_UP="dnsproxy"; export PIDOF_UP
r=$(run naive)
if [ "$(cat "$TMP/vsh.log")" = "restart-svc naive" ]; then ok "naive: restarted when only its dnsproxy was running"; else bad "dnsproxy-only restart: $(cat "$TMP/vsh.log" 2>/dev/null)"; fi
reset; PIDOF_UP="xray hysteria"; export PIDOF_UP
r=$(run naive)
if [ "$(echo "$r" | jq -r .state)" = done ] && [ ! -e "$TMP/vsh.log" ]; then ok "naive: a service that is not running is not started"; else bad "naive not started: $(cat "$TMP/vsh.log" 2>/dev/null)"; fi
# restart failure: both old binaries are put back
reset; printf '#!/bin/sh\necho oldnaive\n' > "$INS/naive"; printf '#!/bin/sh\necho olddns\n' > "$INS/dnsproxy"; chmod 755 "$INS/naive" "$INS/dnsproxy"
PIDOF_UP="naive dnsproxy"; VSH_FAIL=1; export PIDOF_UP VSH_FAIL
r=$(run naive)
if [ "$(echo "$r" | jq -r .state)" = error ] && echo "$r" | jq -r .error | grep -q 'old one was put back' && grep -q oldnaive "$INS/naive" && grep -q olddns "$INS/dnsproxy" && [ "$(wc -l < "$TMP/vsh.log")" = 2 ]; then
	ok "naive: a failed restart puts back both old binaries and restarts them"
else bad "naive rollback: $r"; fi
# one combined progress: naive part stays within 0-70, dnsproxy part within 70-100
reset
REALCURL=$(command -v curl)
cat > "$BIN/curl" <<EOF2
#!/bin/sh
case "\$*" in
  *naiveproxy-v1.2.3-4-openwrt*) printf '\\r######              50.0%%' >&2; sleep 3; printf '\\r################## 100.0%%' >&2;;
  *dnsproxy-linux-arm64*) printf '\\r######              50.0%%' >&2; sleep 3; printf '\\r################## 100.0%%' >&2;;
esac
exec "$REALCURL" "\$@"
EOF2
chmod 755 "$BIN/curl"
"$IC" start naive >/dev/null
nseen=""; dseen=""; maxp=0; i=0
while [ $i -lt 60 ]; do
	st=$(cat "$SD/aurora-install-naive.json" 2>/dev/null)
	p=$(echo "$st" | jq -r '.percent // 0' 2>/dev/null); g=$(echo "$st" | jq -r '.stage // ""' 2>/dev/null); sta=$(echo "$st" | jq -r '.state // ""' 2>/dev/null)
	[ "$sta" = running ] && [ "${p:-0}" -lt "$maxp" ] && maxp=-1
	[ "$maxp" -ge 0 ] && maxp=$p
	if [ "$sta" = running ] && [ "$g" = downloading ]; then
		if [ ! -x "$INS/naive" ] && [ -z "$dseen" ] && [ "$p" -gt 12 ] && [ "$p" -le 70 ]; then nseen=$p; fi
		if [ -n "$nseen" ] && [ "$p" -ge 74 ] && [ "$p" -lt 90 ]; then dseen=$p; fi
	fi
	[ "$sta" = done ] || [ "$sta" = error ] && break
	sleep 0.25; i=$((i+1))
done
rm -f "$BIN/curl"
if [ -n "$nseen" ] && [ -n "$dseen" ] && [ "$maxp" -ge 0 ] && [ "$(jq -r .state "$SD/aurora-install-naive.json")" = done ]; then ok "naive: one progress bar, Naive download at ${nseen}% (<=70), dnsproxy at ${dseen}% (70-100), never backwards"; else bad "naive progress: n=$nseen d=$dseen max=$maxp $(cat "$SD/aurora-install-naive.json")"; fi
# SOCKS fallback also covers dnsproxy
reset; echo naive > "$TMP/etc/proto"
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
AURORA_SOCKS_FORCE=127.0.0.1:10828; export AURORA_SOCKS_FORCE
r=$(run naive)
rm -f "$BIN/curl"; unset AURORA_SOCKS_FORCE
if [ "$(echo "$r" | jq -r .state)" = done ] && grep -q -- '--socks5-hostname 127.0.0.1:10828.*dnsproxy-linux-arm64' "$TMP/curl.log" && grep -q "dnsproxy" "$TMP/curl.log"; then ok "dnsproxy download falls back to the active protocol's SOCKS entry like the rest"; else bad "dnsproxy socks: $r"; fi
# dnsproxy architecture map
eval "$(sed -n '/^arch_dp()/,/^}/p' "$IC")"
chk() { # openwrt-arch uname expected
	printf "DISTRIB_ARCH='%s'\n" "$1" > "$TMP/osrel"
	[ -n "$1" ] || rm -f "$TMP/osrel"
	got=$(AURORA_OPENWRT_RELEASE=$TMP/osrel arch_dp 2>/dev/null)
	[ "$got" = "$3" ]
}
archok=1
chk aarch64_cortex-a53 aarch64 arm64 || archok=0
chk aarch64_generic x arm64 || archok=0
chk x86_64 x amd64 || archok=0
chk i386_pentium4 x 386 || archok=0
chk arm_cortex-a7_neon-vfpv4 x arm7 || archok=0
chk arm_cortex-a9 x arm7 || archok=0
chk arm_arm926ej-s x arm5 || archok=0
chk mipsel_24kc x mipsle || archok=0
chk mips_24kc x mips || archok=0
chk mips64_octeonplus x mips64 || archok=0
chk "" aarch64 arm64 || archok=0
if [ "$archok" = 1 ]; then ok "dnsproxy arch map: aarch64->arm64, x86_64->amd64, arm->arm5/6/7, mips->mips/mipsle/mips64 (linux-arm64 for aarch64)"; else bad "dnsproxy arch map"; fi

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
