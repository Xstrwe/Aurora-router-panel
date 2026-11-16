#!/bin/sh
# Status card, restart failures, egress IP and the VPN/proxy page.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SH=$ROOT/files/etc/xray/vless.sh
CGI=$ROOT/files/www-vpn-panel/cgi-bin/vpn
LIB=$ROOT/files/usr/libexec/vpn-panel/autoupdate-lib.sh
VC=$ROOT/tools/vercmp.sh
fail=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
D=$TMP/etc/xray
mkdir -p "$D/autoupdate" "$TMP/bin" "$TMP/hooks"

printf 'vless://00000000-0000-0000-0000-000000000000@192.0.2.10:443?sni=first.example\n' > "$D/link.txt"
printf 'hysteria2://testpass@192.0.2.20:443?sni=hy.example\n' > "$D/hy2.txt"
printf 'naive+https://user:pass@192.0.2.30:8445\n' > "$D/naive.txt"
printf '[Interface]\nPrivateKey = TEST\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = TEST\nEndpoint = 192.0.2.40:51820\nAllowedIPs = 0.0.0.0/0\n' > "$D/wg.conf"
echo 192.0.2.10 > "$D/server_ip"
echo ru > "$D/mode"
echo '{}' > "$D/config.json"
cat > "$D/http.json" <<'JSON'
{"address":"proxy.example","port":8080,"user":"u","pass":"p","tls":true,"sni":"proxy.example","allowInsecure":false}
JSON

cat > "$TMP/bin/pidof" <<'EOF'
#!/bin/sh
UP=$PIDOF_UP
[ -n "${PIDOF_FILE:-}" ] && UP=$(cat "$PIDOF_FILE" 2>/dev/null)
for p in $UP; do
	if [ "$p" = "$1" ]; then echo 4242; exit 0; fi
done
exit 1
EOF
cat > "$TMP/bin/nft" <<'EOF'
#!/bin/sh
if [ "${NFT_FAIL:-}" = 1 ]; then exit 1; fi
exit 0
EOF
cat > "$TMP/bin/xray-ok" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP/bin/xray-badcfg" <<'EOF'
#!/bin/sh
if [ "$1" = run ] && [ "$2" = -test ]; then
	echo "Failed to parse config: invalid outbound" >&2
	exit 1
fi
exit 0
EOF
cat > "$TMP/bin/xray-denied" <<'EOF'
#!/bin/sh
if [ "$1" = run ] && [ "$2" = -test ]; then
	echo "open /etc/xray/config.json: permission denied" >&2
	exit 1
fi
exit 0
EOF
chmod 755 "$TMP/bin/pidof" "$TMP/bin/nft" "$TMP/bin/xray-ok" "$TMP/bin/xray-badcfg" "$TMP/bin/xray-denied"

cat > "$TMP/hooks/xrestart-ok.sh" <<EOF
#!/bin/sh
echo ok >> "$D/xrestart.log"
echo xray >> "$D/order.log"
exit 0
EOF
cat > "$TMP/hooks/xrestart-fail.sh" <<EOF
#!/bin/sh
echo 'startup failed: boom' > /tmp/xray-restart.err
exit 1
EOF
cat > "$TMP/hooks/xrestart-denied.sh" <<EOF
#!/bin/sh
echo 'Permission denied' > /tmp/xray-restart.err
exit 1
EOF
cat > "$TMP/hooks/xrestart-eaddr.sh" <<EOF
#!/bin/sh
echo 'failed to listen TCP on 0.0.0.0:10808: address already in use' > /tmp/xray-restart.err
exit 1
EOF
cat > "$TMP/hooks/svc-ok.sh" <<EOF
#!/bin/sh
printf '%s %s\n' "\$1" "\$2" >> "$D/svc.log"
echo "\$1" >> "$D/order.log"
exit 0
EOF
cat > "$TMP/hooks/svc-fail.sh" <<EOF
#!/bin/sh
echo 'client.yaml: auth failed' > /tmp/aurora-restart-\$1.err
exit 1
EOF
cat > "$TMP/hooks/svc-noscript.sh" <<EOF
#!/bin/sh
echo "no script /etc/init.d/\$1" > /tmp/aurora-restart-\$1.err
exit 3
EOF
cat > "$TMP/hooks/egress-final.sh" <<'EOF'
#!/bin/sh
printf '%s\n' '203.0.113.50'
EOF
cat > "$TMP/hooks/egress-junk.sh" <<'EOF'
#!/bin/sh
printf '%s\n' 'not-an-ip'
EOF
chmod 755 "$TMP/hooks/"*.sh
cat > "$TMP/hooks/vless-fail.sh" <<'EOF'
#!/bin/sh
case "$1" in status) printf 'running=1\nhysteria=0\nnaive=0\ntproxy=1\nmode=ru\nproto=vless\nserver_ip=\n';; *) echo "ERROR: boom";; esac
EOF
cat > "$TMP/bin/curl" <<EOF
#!/bin/sh
echo x >> "$TMP/curl.count"
printf '%s\n' '203.0.113.9'
EOF
chmod 755 "$TMP/bin/curl" "$TMP/hooks/vless-fail.sh"
# Fake init dir: a daemon that starts, and one that starts and dies after a second.
mkdir -p "$TMP/initd"
cat > "$TMP/initd/good-client" <<EOF
#!/bin/sh
[ "\$1" = restart ] && echo good > "$TMP/pidof.state"
exit 0
EOF
cat > "$TMP/initd/crash-client" <<EOF
#!/bin/sh
if [ "\$1" = restart ]; then echo crash > "$TMP/pidof.state"; ( sleep 1; : > "$TMP/pidof.state" ) & fi
exit 0
EOF
chmod 755 "$TMP/initd/"*

export VLESS_PANEL_DIR=$D
export VLESS_AU_LIB=$LIB
export VLESS_SH=$SH
export PATH="$TMP/bin:$PATH"
export PIDOF_UP="xray"
export VLESS_AU_STABLE_SECS=0
cat > "$TMP/hooks/steer.sh" <<EOF
#!/bin/sh
echo "\$1 \$2" >> "$D/steer.log"
exit 0
EOF
chmod 755 "$TMP/hooks/steer.sh"
export VLESS_AU_STEER="$TMP/hooks/steer.sh"
export VLESS_AU_PROBE_PAUSE=0
# WireGuard: not installed unless a test says otherwise; `ip link show wg-aurora` follows a state file.
export VLESS_WG_BIN="$TMP/no-wg"
export VLESS_WG_SYSMOD="$TMP/no-wg-module"
export VLESS_WG_KO="$TMP/no-ko"
cat > "$TMP/bin/ip" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "link show" ]; then [ -f "$TMP/wgup.state" ]; exit \$?; fi
exit 0
EOF
chmod 755 "$TMP/bin/ip"
export VLESS_AU_XRETRY_PAUSE=0
export VLESS_AU_RECOVER_LOCK="$TMP/recover.lock"
cat > "$TMP/hooks/recover-rec.sh" <<EOF
#!/bin/sh
echo recover >> "$D/recover.log"
EOF
chmod 755 "$TMP/hooks/recover-rec.sh"
export VLESS_AU_RECOVER_CMD="$TMP/hooks/recover-rec.sh"
unset VLESS_AU_PORTS_BUSY VLESS_AU_SVC_RESTART VLESS_AU_EGRESS VLESS_AU_SKIP_XRAY_TEST || true

run() {
	# shellcheck disable=SC2086
	env VLESS_XRAY_BIN="$1" VLESS_AU_XRESTART="$2" ${3:+VLESS_AU_SVC_RESTART="$3"} "$SH" restart 2>/dev/null
}

# --- version is a letter iteration after 1.4.0 ---
ver=$(sed -n 's/^Version: //p' "$ROOT/control/control" | head -1)
cls=$("$VC" classify "$ver")
if [ "$ver" = 1.5.0a5 ] && [ "$cls" = pre ]; then
	ok "package version 1.5.0a5 is a pre-release"
else
	bad "version ($ver class=$cls)"
fi

# --- restart: missing binary, before any start ---
rm -f "$D/xrestart.log"
echo vless > "$D/proto"
out=$(env VLESS_XRAY_BIN="$TMP/no-such-xray" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: FILE MISSING' \
   && printf '%s\n' "$out" | grep -q '^HINT: INSTALL XRAY' \
   && [ ! -s "$D/xrestart.log" ]; then
	ok "restart missing xray names the file and the install hint"
else
	bad "restart missing xray ($out)"
fi

# --- restart: config test failure is not a port or a generic start error ---
: > "$D/xrestart.log"
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-badcfg" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q 'XRAY REJECTED THE CONFIG: FAILED TO PARSE CONFIG: INVALID OUTBOUND' \
   && printf '%s\n' "$out" | grep -q '^HINT: FIX THE CONFIG' \
   && ! grep -q ok "$D/xrestart.log"; then
	ok "restart reports a config-test failure and does not start xray"
else
	bad "restart bad config ($out)"
fi

# --- restart: permission denied from the config test ---
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-denied" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: NO PERMISSION FOR THE CONFIG' \
   && printf '%s\n' "$out" | grep -q '^HINT: RESTART AS ROOT'; then
	ok "restart turns permission denied into a root/chmod hint"
else
	bad "restart permission ($out)"
fi

# --- restart: address already in use ---
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-eaddr.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: PORT IN USE:' \
   && printf '%s\n' "$out" | grep -q 'NETSTAT'; then
	ok "restart reports a busy port and how to free it"
else
	bad "restart eaddr ($out)"
fi

# --- restart: ports busy even without that phrase in the log ---
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-fail.sh" VLESS_AU_PORTS_BUSY=10808/TCP "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: PORT IN USE: 10808/TCP'; then
	ok "restart reports the hooked busy port"
else
	bad "restart ports hook ($out)"
fi

# --- restart: generic start failure keeps the raw log, uppercased ---
unset VLESS_AU_PORTS_BUSY
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-fail.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q 'XRAY DID NOT START: STARTUP FAILED: BOOM' \
   && printf '%s\n' "$out" | grep -q '^HINT: CHECK LOGREAD -E XRAY'; then
	ok "restart keeps the raw start error and a logread hint"
else
	bad "restart generic ($out)"
fi

# --- restart: permission denied from the init script, after a clean config test ---
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-denied.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: NO PERMISSION TO START XRAY' \
   && printf '%s\n' "$out" | grep -q 'CHMOD 755'; then
	ok "restart hints chmod when the init script is denied"
else
	bad "restart init denied ($out)"
fi

# --- restart: vless success does not touch hysteria/naive ---
rm -f "$D/xrestart.log" "$D/svc.log"
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" VLESS_AU_SVC_RESTART="$TMP/hooks/svc-ok.sh" "$SH" restart 2>/dev/null || true)
if [ "$out" = OK ] && grep -q ok "$D/xrestart.log" && [ ! -s "$D/svc.log" ]; then
	ok "vless restart restarts xray only"
else
	bad "vless restart ($out svc=$(cat "$D/svc.log" 2>/dev/null))"
fi

# --- restart: hy2 also restarts hysteria; missing binary fails first ---
echo hy2 > "$D/proto"
rm -f "$D/xrestart.log"
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/no-hysteria" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: FILE MISSING' \
   && printf '%s\n' "$out" | grep -q '^HINT: INSTALL HYSTERIA' \
   && [ ! -s "$D/xrestart.log" ]; then
	ok "hy2 restart stops on a missing hysteria binary"
else
	bad "hy2 missing hysteria ($out)"
fi

rm -f "$D/svc.log" "$D/xrestart.log"
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" VLESS_AU_SVC_RESTART="$TMP/hooks/svc-ok.sh" "$SH" restart 2>/dev/null || true)
if [ "$out" = OK ] && grep -q 'hysteria-client hysteria' "$D/svc.log"; then
	ok "hy2 restart restarts hysteria-client"
else
	bad "hy2 restart ($out svc=$(cat "$D/svc.log" 2>/dev/null))"
fi

out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" VLESS_AU_SVC_RESTART="$TMP/hooks/svc-fail.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q 'HYSTERIA DID NOT START: CLIENT.YAML: AUTH FAILED' \
   && printf '%s\n' "$out" | grep -q '/ETC/HYSTERIA/CLIENT.YAML'; then
	ok "hy2 restart surfaces the hysteria log and the yaml hint"
else
	bad "hy2 hysteria fail ($out)"
fi

out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" VLESS_AU_SVC_RESTART="$TMP/hooks/svc-noscript.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: SCRIPT MISSING: /ETC/INIT.D/HYSTERIA-CLIENT' \
   && printf '%s\n' "$out" | grep -q 'REINSTALL THE'; then
	ok "missing hysteria init script tells you to reinstall"
else
	bad "hy2 noscript ($out)"
fi

# --- naive ---
echo naive > "$D/proto"
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_NAIVE_BIN="$TMP/no-naive" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^HINT: INSTALL NAIVE WITH /USR/LIBEXEC/VPN-PANEL/INSTALL-NAIVE.SH'; then
	ok "naive restart points at install-naive.sh"
else
	bad "naive missing ($out)"
fi
rm -f "$D/svc.log"
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_NAIVE_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" VLESS_AU_SVC_RESTART="$TMP/hooks/svc-ok.sh" "$SH" restart 2>/dev/null || true)
if [ "$out" = OK ] && grep -q 'naive-client naive' "$D/svc.log"; then
	ok "naive restart restarts naive-client"
else
	bad "naive restart ($out)"
fi

# --- no config file ---
echo vless > "$D/proto"
mv "$D/config.json" "$D/config.json.bak"
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" "$SH" restart 2>/dev/null || true)
mv "$D/config.json.bak" "$D/config.json"
if printf '%s\n' "$out" | grep -q 'CONFIG FILE MISSING:' \
   && printf '%s\n' "$out" | grep -q 'PRESS «CONNECT»'; then
	ok "restart without a config tells you to press Connect"
else
	bad "restart no config ($out)"
fi

# --- egress is the echo result, never the saved first hop ---
echo hy2 > "$D/proto"
got=$(env VLESS_AU_EGRESS="$TMP/hooks/egress-final.sh" "$SH" egress 2>/dev/null || true)
if [ "$got" = 203.0.113.50 ]; then
	ok "egress prints the far-end echo address"
else
	bad "egress ($got)"
fi
if ! env VLESS_AU_EGRESS="$TMP/hooks/egress-junk.sh" "$SH" egress >/tmp/aurora-egress-junk.out 2>/dev/null; then
	if [ ! -s /tmp/aurora-egress-junk.out ] && ! grep -q '192.0.2.10' /tmp/aurora-egress-junk.out 2>/dev/null; then
		ok "egress refuses a non-IP and does not fall back to the server address"
	else
		bad "egress junk leaked ($(cat /tmp/aurora-egress-junk.out 2>/dev/null))"
	fi
else
	bad "egress junk should fail"
fi
rm -f /tmp/aurora-egress-junk.out
if ! grep -q 'server_ip' "$SH" || grep -n 'egress_ip()' -A 25 "$SH" | grep -q 'server_ip'; then
	# The function body must not read the first hop. A mention of server_ip in a comment is ok
	# only outside the function; reject it inside egress_ip.
	body=$(awk '/^egress_ip\(\)/{p=1} p{print} /^MODE=/{exit}' "$SH")
	if printf '%s\n' "$body" | grep -q 'server_ip'; then
		bad "egress_ip reads server_ip"
	else
		ok "egress_ip does not read server_ip"
	fi
else
	ok "egress_ip does not read server_ip"
fi
if grep -q -- '--socks5-hostname 127.0.0.1:10808' "$SH"; then
	ok "egress probe enters the chain at the local xray SOCKS inbound"
else
	bad "egress probe port"
fi

# --- rendered page ---
render() {
	env PIDOF_UP="$1" NFT_FAIL="${2:-}" VLESS_AU_EGRESS="$3" \
		VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_NAIVE_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/no-hysteria" \
		REQUEST_METHOD=GET \
		"$CGI"
}

html=$(render xray 0 "$TMP/hooks/egress-final.sh")
ipget() { env PIDOF_UP="$1" VLESS_AU_EGRESS="$2" REQUEST_METHOD=GET QUERY_STRING=ip "$CGI"; }
row() { printf '%s\n' "$html" | sed -n "s/.*<tr><td>$1<\\/td><td>\\(.*\\)<\\/td><\\/tr>.*/\\1/p" | head -1; }
proto=$(row 'Protocol:')
exitrow=$(printf '%s\n' "$html" | grep '<td>Egress IP:</td>' | head -1)
svc=$(row 'Service (daemon):')
if printf '%s' "$proto" | grep -q '>Hysteria2<' \
   && printf '%s' "$exitrow" | grep -q 'id=egress' \
   && ! printf '%s' "$exitrow" | grep -q '192.0.2' \
   && printf '%s' "$svc" | grep -q 'color:#1a7f37" title="running">Xray</span>' \
   && printf '%s' "$svc" | grep -q 'color:#c62828;font-weight:700" title="not installed">Hysteria</span>' \
   && ! printf '%s\n' "$html" | grep -q 'Restart service' \
   && printf '%s' "$html" | grep -q '192.0.2.20:443'; then
	ok "status card shows the connected protocol, daemon colours and the far-end IP"
else
	bad "status card proto=$proto exit=$exitrow"
fi

# The egress IP is fetched after load via ?ip; the page itself never runs the probe.
ipout=$(ipget xray "$TMP/hooks/egress-final.sh")
ipjunk=$(ipget xray "$TMP/hooks/egress-junk.sh")
if printf '%s\n' "$ipout" | grep -q '^Content-Type: text/plain' \
   && [ "$(printf '%s\n' "$ipout" | sed '1,/^$/d')" = 203.0.113.50 ] \
   && [ -z "$(printf '%s\n' "$ipjunk" | sed '1,/^$/d')" ] \
   && printf '%s\n' "$html" | grep -q "fetch('?ip'"; then
	ok "egress IP is served by GET ?ip and fetched from JS after load"
else
	bad "ip endpoint ($ipout / $ipjunk)"
fi
cat > "$TMP/hooks/egress-slow.sh" <<'EOF'
#!/bin/sh
sleep 20
echo 203.0.113.1
EOF
chmod 755 "$TMP/hooks/egress-slow.sh"
t0=$(date +%s)
render xray 0 "$TMP/hooks/egress-slow.sh" >/dev/null
t1=$(date +%s)
if [ $((t1 - t0)) -lt 5 ]; then ok "page loads without waiting for a slow egress probe"; else bad "page blocked $((t1 - t0))s"; fi
rm -f "$TMP/hooks/egress-slow.sh"

# egress probe: one curl, cached for 60 s, invalidated by a different key
rm -f "$TMP/curl.count" "$TMP/egress.cache"
echo vless > "$D/proto"
g1=$(env VLESS_AU_EGRESS_CACHE="$TMP/egress.cache" "$SH" egress 2>/dev/null || true)
g2=$(env VLESS_AU_EGRESS_CACHE="$TMP/egress.cache" "$SH" egress 2>/dev/null || true)
n=$(wc -l < "$TMP/curl.count" | tr -d ' ')
if [ "$g1" = 203.0.113.9 ] && [ "$g2" = 203.0.113.9 ] && [ "$n" = 1 ] \
   && grep -q -- '-m 3 ' "$SH"; then
	ok "egress is one 3 s probe, then served from the 60 s cache"
else
	bad "egress cache g1=$g1 g2=$g2 curls=$n"
fi
echo hy2 > "$D/proto"
env PIDOF_UP="xray hysteria" VLESS_AU_EGRESS_CACHE="$TMP/egress.cache" "$SH" egress >/dev/null 2>&1 || true
n=$(wc -l < "$TMP/curl.count" | tr -d ' ')
echo hy2 > "$D/proto"
if [ "$n" = 2 ]; then ok "egress cache is dropped when the protocol changes"; else bad "egress cache key (curls=$n)"; fi

# --- restart order, stability and tproxy ---
echo hy2 > "$D/proto"
rm -f "$D/order.log" "$D/svc.log" "$D/xrestart.log"
rm -f "$D/steer.log"
env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" VLESS_AU_SVC_RESTART="$TMP/hooks/svc-ok.sh" "$SH" restart >/dev/null 2>&1 || true
if [ "$(tr '\n' ' ' < "$D/order.log")" = "hysteria-client " ] && [ ! -e "$D/xrestart.log" ] \
   && [ "$(tr '\n' ' ' < "$D/steer.log")" = "hy down hy up " ]; then
	ok "restart with Hysteria active restarts only Hysteria (Xray untouched) and re-applies its steering"
else
	bad "restart order ($(tr '\n' ' ' < "$D/order.log" 2>/dev/null))"
fi
echo vless > "$D/proto"

# restart_init on its own: the real function, against a fake init dir.
body=$(awk '/^proc_stable\(\)/{p=1} p{print} /^require_bin\(\)/{exit}' "$SH" | sed '$d')
cat > "$TMP/ri.sh" <<EOF
INITD=$TMP/initd
STABLE_SECS=2
$body
restart_init "\$1" "\$2"
EOF
echo none > "$TMP/pidof.state"
if env PIDOF_FILE="$TMP/pidof.state" sh "$TMP/ri.sh" good-client good; then
	ok "restart_init accepts a daemon that stays up"
else
	bad "restart_init good"
fi
if ! env PIDOF_FILE="$TMP/pidof.state" sh "$TMP/ri.sh" crash-client crash && grep -q 'exited right away' /tmp/aurora-restart-crash-client.err; then
	ok "restart_init rejects a daemon that dies right after start"
else
	bad "restart_init crash"
fi
rm -f /tmp/aurora-restart-good-client.err /tmp/aurora-restart-crash-client.err "$TMP/ri.sh"

# Transparent mode must be up after a restart (unless switched off).
rm -f "$D/tproxy.disabled"
out=$(env NFT_FAIL=1 VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: TRANSPARENT MODE IS NOT ACTIVE' \
   && printf '%s\n' "$out" | grep -q '^HINT: .*TPROXY.SH UP'; then
	ok "restart reports a missing nft table"
else
	bad "restart tproxy check ($out)"
fi
touch "$D/tproxy.disabled"
out=$(env NFT_FAIL=1 VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" "$SH" restart 2>/dev/null || true)
rm -f "$D/tproxy.disabled"
if [ "$out" = OK ]; then ok "restart does not require nft when transparent mode is switched off"; else bad "restart tproxy disabled ($out)"; fi

# Four VPN fields, fixed, WireGuard included; proxy button vs expanded card.
ntxt=$(printf '%s\n' "$html" | grep -c '<textarea ' || true)
if [ "$ntxt" = 4 ] \
   && printf '%s\n' "$html" | grep -q 'name=wg rows=2' \
   && printf '%s\n' "$html" | grep -q 'id=card-socks hidden' \
   && printf '%s\n' "$html" | grep -q '>Add SOCKS5<' \
   && printf '%s\n' "$html" | grep -q 'id=card-http>' \
   && ! printf '%s\n' "$html" | grep -q 'id=card-http hidden' \
   && printf '%s\n' "$html" | grep -q 'value="proxy.example"' \
   && printf '%s\n' "$html" | grep -q 'IPv6 is not proxied.' \
   && printf '%s\n' "$html" | grep -q 'Local proxies for individual apps'; then
	ok "VPN fields are 2-line, SOCKS is behind a button, saved HTTP is expanded"
else
	bad "rendered layout (textareas=$ntxt)"
fi

# Two visible lines exactly: height = 2 * line-height + borders, no vertical padding.
if grep -q 'line-height:18px;padding:0 8px;height:38px;min-height:38px;max-height:38px' "$CGI"; then
	ok "link fields are exactly two lines high"
else
	bad "textarea height"
fi

# SNI / insecure row: shown with TLS on, hidden with TLS off, and [hidden] wins in CSS.
if printf '%s\n' "$html" | grep -q 'class="tls-extra span2">' \
   && grep -q '.tls-extra\[hidden\]{display:none}' "$CGI" \
   && ! grep -q 'style="display:contents"' "$CGI"; then
	ok "HTTP SNI row is shown with TLS on; CSS lets hidden win"
else
	bad "tls-extra markup"
fi
cp "$D/http.json" "$D/http.json.bak"
echo '{"address":"proxy.example","port":8080,"tls":false}' > "$D/http.json"
htmlt=$(render xray 0 "$TMP/hooks/egress-final.sh")
mv "$D/http.json.bak" "$D/http.json"
if printf '%s\n' "$htmlt" | grep -q 'class="tls-extra span2" hidden>'; then
	ok "HTTP SNI row starts hidden when TLS is off"
else
	bad "tls-extra hidden when TLS off"
fi

# A failed SOCKS5 save keeps the card open with what was typed.
body='action=sockssave&proto=socks&addr=10.9.9.9&port=1080&user=bob&pass=s3'
rm -f "$D/socks.json"
htmlf=$(printf '%s' "$body" | env PIDOF_UP=xray VLESS_SH="$TMP/hooks/vless-fail.sh" \
	REQUEST_METHOD=POST CONTENT_LENGTH=${#body} "$CGI")
if printf '%s\n' "$htmlf" | grep -q 'id=card-socks>' \
   && printf '%s\n' "$htmlf" | grep -q 'value="10.9.9.9"' \
   && printf '%s\n' "$htmlf" | grep -q 'value="bob"' \
   && printf '%s\n' "$htmlf" | grep -q 'class=msg>ERROR'; then
	ok "failed SOCKS5 save keeps the card open with the typed values"
else
	bad "failed save keeps values"
fi

# SOCKS5 is the connected protocol when that Connect button was used.
echo socks > "$D/proto"
printf '%s\n' '{"address":"10.0.0.8","port":1080,"user":"","pass":""}' > "$D/socks.json"
html3=$(render xray 0 "$TMP/hooks/egress-final.sh")
if printf '%s\n' "$html3" | grep -q '<b>SOCKS5</b>' \
   && printf '%s\n' "$html3" | grep -q '10.0.0.8:1080' \
   && ! printf '%s\n' "$html3" | sed -n 's/.*<tr><td>Protocol:<\/td><td>\(.*\)<\/td><\/tr>.*/\1/p' | grep -q 'VLESS'; then
	ok "protocol row follows a connected SOCKS5 upstream"
else
	bad "socks protocol row"
fi
rm -f "$D/socks.json"
echo hy2 > "$D/proto"

# Restart failure banner is the first body content, reason red, fix green.
body='action=restartsvc&svc=xray'
html4=$(printf '%s' "$body" | env PIDOF_UP=xray VLESS_XRAY_BIN="$TMP/no-such-xray" \
	REQUEST_METHOD=POST CONTENT_LENGTH=${#body} "$CGI")
# Banner before the title, and no yellow duplicate of the same error.
if printf '%s\n' "$html4" | tr '\n' ' ' | grep -q '<body> *<div class=banner><div class=why>FILE MISSING' \
   && printf '%s\n' "$html4" | grep -q 'class=why' \
   && printf '%s\n' "$html4" | grep -q 'class=how' \
   && printf '%s\n' "$html4" | grep -q 'INSTALL XRAY' \
   && ! printf '%s\n' "$html4" | grep -q 'class=msg'; then
	ok "restart failure is a top banner with reason and fix"
else
	bad "restart banner"
fi

# Banner colours are red for the reason and green for the fix.
if grep -q '.banner .why{color:#c62828' "$CGI" && grep -q '.banner .how{color:#1a7f37' "$CGI"; then
	ok "banner colours are red for the reason and green for the fix"
else
	bad "banner colours"
fi

# --- one row of services, each with its own small restart button ---
nrb=$(printf '%s\n' "$html" | grep -o 'class=rb' | wc -l | tr -d ' ')
if [ "$nrb" = 4 ] \
   && printf '%s' "$svc" | grep -q 'Xray</span>.*</span> / <span class=svc>.*Naive</span>.*</span> / <span class=svc>.*Hysteria</span>.*</span> / <span class=svc>.*WireGuard</span>' \
   && printf '%s\n' "$html" | grep -q 'name=svc value=wireguard' \
   && grep -q 'button.rb{[^}]*width:1.2em;height:1.2em' "$CGI"; then
	ok "services are one row: Xray / Naive / Hysteria / WireGuard, each with a small restart button"
else
	bad "service row (buttons=$nrb)"
fi
# Mode is the first row of the status card (above the transparent-mode row) and still posts action=mode.
if printf '%s\n' "$html" | tr '\n' ' ' | grep -q '<div class=c id=status><table> *<tr><td>Mode:</td><td><form method=post class=modef><input type=hidden name=action value=mode>.*</form></td></tr> *<tr><td>Transparent mode for the network:</td>' \
   && ! printf '%s\n' "$html" | grep -q 'id=modecard' \
   && [ "$(printf '%s\n' "$html" | grep -c '<b>Mode:</b>')" = 0 ]; then
	ok "the mode selector is the first row of the status card; no separate mode card"
else
	bad "mode row position"
fi
# The mode action still works.
body='action=mode&mode=all'
htmlm=$(printf '%s' "$body" | env PIDOF_UP=xray VLESS_SH="$TMP/hooks/vless-fail.sh" REQUEST_METHOD=POST CONTENT_LENGTH=${#body} "$CGI")
if printf '%s\n' "$htmlm" | grep -q 'class=msg>ERROR: boom'; then ok "mode POST is still passed to vless.sh mode"; else bad "mode post"; fi
# Whitelist: an unknown or injected service name is refused and nothing runs.
body='action=restartsvc&svc=xray%3Btouch%20/tmp/aurora-pwned'
rm -f /tmp/aurora-pwned
htmli=$(printf '%s' "$body" | env PIDOF_UP=xray REQUEST_METHOD=POST CONTENT_LENGTH=${#body} "$CGI")
if [ ! -e /tmp/aurora-pwned ] && printf '%s\n' "$htmli" | grep -q 'class=why>UNKNOWN SERVICE'; then
	ok "restart accepts only whitelisted service names"
else
	bad "restart whitelist"
fi
rm -f /tmp/aurora-pwned
# Each button restarts only its own service and never changes the active protocol.
echo vless > "$D/proto"
mkdir -p "$TMP/etc-hy" "$TMP/etc-na"
echo 'server: x' > "$TMP/etc-hy/client.yaml"; echo '{}' > "$TMP/etc-na/config.json"
cat > "$TMP/initd/hysteria-client" <<EOF
#!/bin/sh
echo "hysteria-client \$1" >> "$TMP/initd.log"
[ "\$1" = restart ] && echo hysteria > "$TMP/pidof.state"
exit 0
EOF
cat > "$TMP/initd/naive-client" <<EOF
#!/bin/sh
echo "naive-client \$1" >> "$TMP/initd.log"
[ "\$1" = restart ] && echo naive > "$TMP/pidof.state"
exit 0
EOF
chmod 755 "$TMP/initd/"*
rm -f "$TMP/initd.log"; echo none > "$TMP/pidof.state"
svcenv() { env PIDOF_FILE="$TMP/pidof.state" VLESS_INITD="$TMP/initd" VLESS_HYSTERIA_DIR="$TMP/etc-hy" VLESS_NAIVE_DIR="$TMP/etc-na" VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/bin/xray-ok" VLESS_NAIVE_BIN="$TMP/bin/xray-ok" "$@"; }
o1=$(svcenv "$SH" restart-svc hysteria 2>/dev/null || true)
o2=$(svcenv "$SH" restart-svc naive 2>/dev/null || true)
if [ "$o1" = OK ] && [ "$o2" = OK ] \
   && [ "$(cat "$D/proto")" = vless ] \
   && ! grep -q 'enable' "$TMP/initd.log" \
   && ! grep -q xray "$TMP/initd.log" \
   && [ "$(grep -c restart "$TMP/initd.log")" = 2 ]; then
	ok "restarting an idle Hysteria/Naive touches only that daemon, keeps the protocol, does not enable it"
else
	bad "svc restart idle ($o1/$o2: $(cat "$TMP/initd.log" 2>/dev/null | tr '\n' ';'))"
fi
# Active protocol: the daemon is enabled as well.
echo naive > "$D/proto"; rm -f "$TMP/initd.log"
svcenv "$SH" restart-svc naive >/dev/null 2>&1 || true
echo vless > "$D/proto"
if grep -q 'naive-client enable' "$TMP/initd.log"; then ok "restarting the active protocol's daemon also enables it"; else bad "svc enable active"; fi
# Xray / WireGuard restart xray (nft checked), unknown name fails, missing config is reported.
rm -f "$D/xrestart.log"; echo xray > "$TMP/pidof.state"
o3=$(svcenv env VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" "$SH" restart-svc xray 2>/dev/null || true)
o5=$(svcenv env NFT_FAIL=1 VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" "$SH" restart-svc xray 2>/dev/null || true)
o6=$(svcenv "$SH" restart-svc bogus 2>/dev/null || true)
if [ "$o3" = OK ] && [ "$(wc -l < "$D/xrestart.log" | tr -d ' ')" -ge 2 ] \
   && printf '%s\n' "$o5" | grep -q '^ERROR: TRANSPARENT MODE IS NOT ACTIVE' \
   && printf '%s\n' "$o6" | grep -q '^ERROR: UNKNOWN SERVICE'; then
	ok "xray restart checks nft; unknown names are rejected"
else
	bad "svc xray ($o3/$o5/$o6)"
fi
# A daemon that fails to start is reported with a reason and a fix; an uninstalled one too.
o7=$(svcenv env VLESS_NAIVE_BIN="$TMP/no-naive" "$SH" restart-svc naive 2>/dev/null || true)
o8=$(svcenv env VLESS_AU_SVC_RESTART="$TMP/hooks/svc-fail.sh" "$SH" restart-svc hysteria 2>/dev/null || true)
if printf '%s\n' "$o7" | grep -q '^HINT: INSTALL NAIVE' \
   && printf '%s\n' "$o8" | grep -q 'HYSTERIA DID NOT START: CLIENT.YAML: AUTH FAILED'; then
	ok "a failed single-service restart reports the reason and the fix"
else
	bad "svc failure ($o7/$o8)"
fi
rm -f /tmp/aurora-restart-*-client.err

# --- real xrestart path: retries, tproxy, recovery, banner texts ---
cat > "$D/tproxy.sh" <<EOF
#!/bin/sh
echo "\$1" >> "$D/tproxy.log"
EOF
chmod 755 "$D/tproxy.sh"
cat > "$TMP/bin/netstat" <<'EOF'
#!/bin/sh
[ -f "$NETSTAT_FILE" ] && cat "$NETSTAT_FILE"
exit 0
EOF
chmod 755 "$TMP/bin/netstat"
cat > "$TMP/initd/xray-client" <<EOF
#!/bin/sh
case "\$1" in
stop) echo stop >> "$TMP/xinit.log"; : > "$TMP/pidof.state"; : > "$TMP/netstat.out";;
start) echo start >> "$TMP/xinit.log"
  n=\$(grep -c start "$TMP/xinit.log")
  if [ "\$n" -gt "\$(cat "$TMP/xfails")" ]; then
    echo xray > "$TMP/pidof.state"
    printf 'tcp 0 0 :::10808 :::* LISTEN\ntcp 0 0 :::12346 :::* LISTEN\n' > "$TMP/netstat.out"
  fi;;
esac
exit 0
EOF
chmod 755 "$TMP/initd/xray-client"
cat > "$TMP/hooks/log-eaddr.sh" <<'EOF'
#!/bin/sh
echo 'daemon.info xray[1]: Failed to start: app/proxyman/inbound: failed to listen TCP on 12346 > listen tcp 0.0.0.0:12346: bind: address already in use'
EOF
chmod 755 "$TMP/hooks/log-eaddr.sh"
xenv() { env PIDOF_FILE="$TMP/pidof.state" NETSTAT_FILE="$TMP/netstat.out" VLESS_INITD="$TMP/initd" VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XSTART_WAIT=1 VLESS_AU_XRESTART_MAX=30 VLESS_AU_LOGREAD="$TMP/hooks/log-eaddr.sh" "$@"; }
reset_x() { rm -f "$TMP/xinit.log" "$D/tproxy.log" "$D/recover.log" "$D/tproxy.disabled"; echo "$1" > "$TMP/xfails"; echo xray > "$TMP/pidof.state"; : > "$TMP/netstat.out"; }
echo vless > "$D/proto"

# A start that fails twice (port still held) succeeds on the third attempt; transparent mode ends up on.
reset_x 2
o=$(xenv "$SH" restart-svc xray 2>/dev/null || true)
if [ "$o" = OK ] && [ "$(grep -c start "$TMP/xinit.log")" = 3 ] && tail -1 "$D/tproxy.log" | grep -q up && [ ! -e "$D/recover.log" ]; then
	ok "xray restart retries a failed start and ends with transparent mode on"
else
	bad "xray retry ($o starts=$(grep -c start "$TMP/xinit.log" 2>/dev/null) tproxy=$(tr '\n' ' ' < "$D/tproxy.log" 2>/dev/null))"
fi

# A start that never works: banner names the port from the log, recovery is started, LAN is left direct.
reset_x 99
o=$(xenv VLESS_AU_XRESTART_MAX=2 "$SH" restart-svc xray 2>/dev/null || true)
if printf '%s\n' "$o" | grep -q '^ERROR: PORT IN USE: 12346/TCP' \
   && printf '%s\n' "$o" | grep -q 'AUTOMATIC RECOVERY' \
   && [ -s "$D/recover.log" ] && tail -1 "$D/tproxy.log" | grep -q down; then
	ok "a failed xray restart reports the real reason, starts recovery and does not leave a blackhole"
else
	bad "xray fail ($o | recover=$(cat "$D/recover.log" 2>/dev/null) tproxy=$(tr '\n' ' ' < "$D/tproxy.log" 2>/dev/null))"
fi

# Transparent mode switched off by the user: no recovery is started.
reset_x 99
touch "$D/tproxy.disabled"
o=$(xenv VLESS_AU_XRESTART_MAX=2 "$SH" restart-svc xray 2>/dev/null || true)
if printf '%s\n' "$o" | grep -q '^ERROR:' && [ ! -e "$D/recover.log" ] && ! printf '%s\n' "$o" | grep -q 'RECOVERY'; then
	ok "no recovery is started while transparent mode is switched off"
else
	bad "recover while disabled ($o)"
fi
rm -f "$D/tproxy.disabled"

# The recover helper itself: restarts Xray, turns transparent mode on, releases its lock.
reset_x 1
rm -rf "$TMP/recover.lock"
xenv env VLESS_AU_RECOVER_CMD= "$SH" recover >/dev/null 2>&1 || true
if [ "$(grep -c start "$TMP/xinit.log")" -ge 2 ] && tail -1 "$D/tproxy.log" | grep -q up && [ ! -d "$TMP/recover.lock" ]; then
	ok "recover restarts Xray until it listens, then switches transparent mode on"
else
	bad "recover helper (starts=$(grep -c start "$TMP/xinit.log" 2>/dev/null))"
fi

# --- WireGuard is its own service (kernel interface wg-aurora, init script wireguard-client) ---
cat > "$TMP/bin/wg-ok" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$TMP/bin/wg-ok"
mkdir -p "$TMP/wg-module"
cat > "$TMP/hooks/svc-wg-ok.sh" <<EOF
#!/bin/sh
printf '%s %s\n' "\$1" "\$2" >> "$D/svc.log"
echo "\$1" >> "$D/order.log"
: > "$TMP/wgup.state"
exit 0
EOF
cat > "$TMP/hooks/svc-wg-fail.sh" <<EOF
#!/bin/sh
echo "\$1" >> "$D/order.log"
echo 'cannot resolve the WireGuard endpoint vpn.example:51820' > /tmp/aurora-restart-wireguard-client.err
exit 1
EOF
chmod 755 "$TMP/hooks/svc-wg-ok.sh" "$TMP/hooks/svc-wg-fail.sh"
cat > "$TMP/bin/ucode" <<'EOF'
#!/bin/sh
# Stand-in for gen.uc: a base config with a placeholder proxy outbound.
echo '{"inbounds":[],"outbounds":[{"tag":"proxy","protocol":"vless","settings":{}},{"tag":"direct","protocol":"freedom"}],"routing":{"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","inboundTag":["dns-in"],"outboundTag":"proxy"}]}}'
EOF
chmod 755 "$TMP/bin/ucode"
wgenv() { env PIDOF_FILE="$TMP/pidof.state" NETSTAT_FILE="$TMP/netstat.out" VLESS_INITD="$TMP/xinitd-none" VLESS_WG_BIN="$TMP/bin/wg-ok" VLESS_WG_SYSMOD="$TMP/wg-module" VLESS_XRAY_BIN="$TMP/bin/xray-ok" "$@"; }
echo '{"protocol":"wireguard","settings":{"secretKey":"K","address":["10.0.0.2/32"],"mtu":1420,"peers":[{"publicKey":"P","endpoint":"192.0.2.40:51820","allowedIPs":["0.0.0.0/0"]}]}}' > "$D/wg.json"
reset_x 0; rm -f "$D/svc.log" "$D/order.log" "$D/xrestart.log" "$TMP/wgup.state"
echo vless > "$D/proto"

# WireGuard button: restarts only wireguard-client; Xray, transparent mode and recovery are never touched.
o=$(wgenv env VLESS_AU_SVC_RESTART="$TMP/hooks/svc-wg-ok.sh" "$SH" restart-svc wireguard 2>/dev/null || true)
if [ "$o" = OK ] && grep -qx 'wireguard-client wireguard' "$D/svc.log" && [ "$(wc -l < "$D/svc.log" | tr -d ' ')" = 1 ] \
   && [ ! -e "$TMP/xinit.log" ] && [ ! -e "$D/tproxy.log" ] && [ ! -e "$D/recover.log" ] && [ ! -e "$D/xrestart.log" ] \
   && [ "$(cat "$D/proto")" = vless ]; then
	ok "the WireGuard restart touches only wireguard-client, never Xray or transparent mode"
else
	bad "wg restart ($o | $(cat "$D/svc.log" 2>/dev/null | tr '\n' ';'))"
fi
# Not installed / config not saved / start failure: concrete banner, Xray untouched.
rm -f "$TMP/wgup.state"
o1=$(env VLESS_WG_BIN="$TMP/no-wg" "$SH" restart-svc wireguard 2>/dev/null || true)
mv "$D/wg.json" "$TMP/wg.json.keep"
o2=$(wgenv "$SH" restart-svc wireguard 2>/dev/null || true)
mv "$TMP/wg.json.keep" "$D/wg.json"
o3=$(wgenv env VLESS_AU_SVC_RESTART="$TMP/hooks/svc-wg-fail.sh" "$SH" restart-svc wireguard 2>/dev/null || true)
if printf '%s\n' "$o1" | grep -q '^ERROR: WIREGUARD IS NOT INSTALLED' \
   && printf '%s\n' "$o1" | grep -q 'KMOD-WIREGUARD WIREGUARD-TOOLS' \
   && printf '%s\n' "$o2" | grep -q '^ERROR: FILE MISSING: /ETC/XRAY/WG.JSON' \
   && printf '%s\n' "$o3" | grep -q '^ERROR: WIREGUARD DID NOT START: CANNOT RESOLVE THE WIREGUARD ENDPOINT VPN.EXAMPLE:51820' \
   && [ ! -e "$TMP/xinit.log" ] && [ ! -e "$D/tproxy.log" ] && [ ! -e "$D/recover.log" ]; then
	ok "WireGuard reports not installed, missing config and start failures with the reason"
else
	bad "wg errors ($o1 | $o2 | $o3)"
fi
# --- independent protocols: each one is its own service, Xray is not involved ---
# Fake init dir that only logs which service was asked to do what.
mkdir -p "$TMP/ni" "$TMP/etc-hy" "$TMP/etc-na"
for nm in xray-client hysteria-client naive-client wireguard-client; do
	printf '#!/bin/sh\necho "%s $1" >> "%s/ni.log"\nexit 0\n' "$nm" "$TMP" > "$TMP/ni/$nm"
done
chmod 755 "$TMP/ni/"*
printf '#!/bin/sh\nexit 0\n' > "$TMP/hooks/probe-ok.sh"
printf '#!/bin/sh\nexit 1\n' > "$TMP/hooks/probe-fail.sh"
chmod 755 "$TMP/hooks/probe-ok.sh" "$TMP/hooks/probe-fail.sh"
echo 'server: hy.example:443' > "$TMP/etc-hy/client.yaml"
echo '{"listen":"socks://127.0.0.1:10828"}' > "$TMP/etc-na/config.json"
SPLITSH=$ROOT/files/usr/libexec/vpn-panel/aurora-split.sh
nenv() { env PIDOF_FILE="$TMP/pidof.state" VLESS_INITD="$TMP/ni" VLESS_HYSTERIA_DIR="$TMP/etc-hy" VLESS_NAIVE_DIR="$TMP/etc-na" \
	VLESS_WG_BIN="$TMP/bin/wg-ok" VLESS_WG_SYSMOD="$TMP/wg-module" VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/bin/xray-ok" VLESS_NAIVE_BIN="$TMP/bin/xray-ok" \
	VLESS_AU_SKIP_XRAY_TEST=1 VLESS_AU_NOLISTENCHECK=1 VLESS_AU_PROBE="$TMP/hooks/probe-ok.sh" VLESS_AU_DNSCHECK="$TMP/hooks/probe-ok.sh" VLESS_AURORA_SPLIT="$SPLITSH" \
	VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" VLESS_AU_SVC_RESTART="$TMP/hooks/svc-ok.sh" "$@"; }
nreset() { rm -f "$D/svc.log" "$D/order.log" "$D/xrestart.log" "$D/steer.log" "$TMP/ni.log" "$TMP/wgup.state"; }
echo 'x: 1' > "$TMP/hy.keep"; cp "$TMP/etc-hy/client.yaml" "$TMP/hy.keep"
cp "$D/config.json" "$TMP/config.keep"
echo vless > "$D/proto"; nreset
o=$(nenv "$SH" proto hy2 2>&1 || true)
if [ "$o" = OK ] && [ "$(cat "$D/proto")" = hy2 ] && [ ! -e "$D/xrestart.log" ] && cmp -s "$D/config.json" "$TMP/config.keep" \
   && [ "$(tr '\n' ' ' < "$D/order.log")" = "hysteria-client " ] \
   && grep -qx 'hy up' "$D/steer.log" && grep -qx 'nv down' "$D/steer.log" && grep -qx 'wg down' "$D/steer.log" \
   && grep -qx 'xray-client stop' "$TMP/ni.log" && grep -qx 'naive-client stop' "$TMP/ni.log" && grep -qx 'wireguard-client stop' "$TMP/ni.log" \
   && ! grep -qx 'hysteria-client stop' "$TMP/ni.log"; then
	ok "Hysteria becomes active on its own: Xray is stopped, never restarted or regenerated; Naive and WireGuard are stopped"
else
	bad "proto hy2 ($o | $(tr '\n' ';' < "$D/order.log" 2>/dev/null) | $(tr '\n' ';' < "$TMP/ni.log" 2>/dev/null) | $(tr '\n' ';' < "$D/steer.log" 2>/dev/null))"
fi
# Naive: saved with its own config (SOCKS + transparent redir), its own server address file; Hysteria is stopped.
printf 'naive+https://user:pass@192.0.2.31:8445\n' > "$TMP/naive.link"
nreset
o=$(nenv "$SH" naivesave "$TMP/naive.link" 2>&1 || true)
if [ "$o" = OK ] && [ "$(cat "$D/proto")" = naive ] && [ ! -e "$D/xrestart.log" ] && cmp -s "$D/config.json" "$TMP/config.keep" \
   && cmp -s "$TMP/etc-hy/client.yaml" "$TMP/hy.keep" \
   && [ "$(tr '\n' ' ' < "$D/order.log")" = "naive-client " ] \
   && [ "$(jq -r '.listen|join(" ")' "$TMP/etc-na/config.json")" = "socks://127.0.0.1:10828 redir://0.0.0.0:12366" ] \
   && [ "$(cat "$TMP/etc-na/server_ip")" = 192.0.2.31 ] \
   && grep -qx 'nv up' "$D/steer.log" && grep -qx 'hy down' "$D/steer.log" && grep -qx 'hysteria-client stop' "$TMP/ni.log" \
   && ! grep -qx 'naive-client stop' "$TMP/ni.log"; then
	ok "Naive becomes active on its own (SOCKS + transparent redir config); Hysteria files and Xray config are untouched"
else
	bad "naivesave ($o | $(tr '\n' ';' < "$D/order.log" 2>/dev/null) | $(tr '\n' ';' < "$TMP/ni.log" 2>/dev/null))"
fi
# WireGuard: its own interface service, nothing from Xray.
cp "$D/wg.json" "$TMP/wg.keep"
nreset
o=$(nenv env VLESS_AU_SVC_RESTART="$TMP/hooks/svc-wg-ok.sh" "$SH" proto wg 2>&1 || true)
if [ "$o" = OK ] && [ "$(cat "$D/proto")" = wg ] && [ ! -e "$D/xrestart.log" ] && cmp -s "$D/config.json" "$TMP/config.keep" \
   && [ "$(tr '\n' ' ' < "$D/order.log")" = "wireguard-client " ] && grep -qx 'wg up' "$D/steer.log" \
   && grep -qx 'naive-client stop' "$TMP/ni.log" && grep -qx 'xray-client stop' "$TMP/ni.log" && ! grep -qx 'wireguard-client stop' "$TMP/ni.log"; then
	ok "WireGuard becomes active on its own: kernel interface service, no Xray outbound, Xray config untouched"
else
	bad "proto wg ($o | $(tr '\n' ';' < "$D/order.log" 2>/dev/null) | $(tr '\n' ';' < "$TMP/ni.log" 2>/dev/null))"
fi
# A failing connectivity check restores the target's files, keeps the previous protocol, stops the target.
cp "$TMP/etc-na/config.json" "$TMP/na.keep"
printf 'naive+https://other:pw@192.0.2.99:9443\n' > "$TMP/naive2.link"
nreset
o=$(nenv env VLESS_AU_PROBE="$TMP/hooks/probe-fail.sh" "$SH" naivesave "$TMP/naive2.link" 2>&1 || true)
if printf '%s\n' "$o" | grep -q '^ERROR: Naive started but has no connectivity' && printf '%s\n' "$o" | grep -q 'previous setup was restored' \
   && [ "$(cat "$D/proto")" = wg ] && cmp -s "$TMP/etc-na/config.json" "$TMP/na.keep" && [ "$(cat "$TMP/etc-na/server_ip")" = 192.0.2.31 ] \
   && [ ! -e "$D/xrestart.log" ] && ! grep -qx 'nv up' "$D/steer.log" && grep -qx 'naive-client stop' "$TMP/ni.log" \
   && ! grep -q 'wireguard-client' "$TMP/ni.log"; then
	ok "a failed Naive check restores Naive's files, stops only Naive and leaves WireGuard active"
else
	bad "naive rollback ($o | $(tr '\n' ';' < "$TMP/ni.log" 2>/dev/null))"
fi
# DNS that does not work after steering is switched on: steering goes back off, the previous protocol stays.
echo wg > "$D/proto"; nreset
o=$(nenv env VLESS_AU_DNSCHECK="$TMP/hooks/probe-fail.sh" "$SH" proto hy2 2>&1 || true)
if printf '%s\n' "$o" | grep -q '^ERROR: DNS does not work through Hysteria' && [ "$(cat "$D/proto")" = wg ] \
   && [ "$(tail -1 "$D/steer.log")" = "hy down" ] && grep -qx 'hy up' "$D/steer.log"; then
	ok "DNS is verified after steering is on; a failure switches that protocol's steering off again"
else
	bad "dns check ($o | $(tr '\n' ';' < "$D/steer.log" 2>/dev/null))"
fi
# Mode of a native protocol is that protocol's own split.conf; Xray is not regenerated.
echo hy2 > "$D/proto"; nreset
o=$(nenv "$SH" mode all 2>&1 || true)
st=$(nenv "$SH" status 2>/dev/null || true)
if [ "$o" = OK ] && grep -qx 'mode all' "$TMP/etc-hy/split.conf" && printf '%s\n' "$st" | grep -qx 'mode=all' && printf '%s\n' "$st" | grep -qx 'proto=hy2' \
   && [ ! -e "$D/xrestart.log" ] && cmp -s "$D/config.json" "$TMP/config.keep" && grep -qx 'hy up' "$D/steer.log" && [ ! -e "$TMP/etc-na/split.conf" ]; then
	ok "mode ru/all with Hysteria active edits only /etc/hysteria/split.conf and re-applies Hysteria's rules"
else
	bad "native mode ($o | $(cat "$TMP/etc-hy/split.conf" 2>/dev/null | tr '\n' ';'))"
fi
nenv "$SH" mode ru >/dev/null 2>&1
# Saving or updating one protocol while another is active touches nothing else.
nreset; echo vless > "$D/proto"
o=$(nenv "$SH" store naive "$TMP/naive2.link" 2>&1 || true)
if [ "$o" = OK ] && [ ! -e "$D/xrestart.log" ] && [ ! -e "$D/svc.log" ] && [ ! -e "$TMP/ni.log" ] && [ ! -e "$D/steer.log" ] \
   && cmp -s "$D/config.json" "$TMP/config.keep" && [ "$(cat "$D/proto")" = vless ] && [ "$(cat "$TMP/etc-na/server_ip")" = 192.0.2.99 ]; then
	ok "saving Naive while VLESS is active restarts nothing and does not regenerate Xray"
else
	bad "store isolation ($o)"
fi
# Active native protocol: a new config reloads only that service (no Xray, no other daemon).
echo naive > "$D/proto"; nreset
o=$(nenv "$SH" reload-with "$TMP/naive.link" naive 2>&1 || true)
if [ "$o" = OK ] && [ "$(tr '\n' ' ' < "$D/order.log")" = "naive-client " ] && [ ! -e "$D/xrestart.log" ] && grep -qx 'nv up' "$D/steer.log" \
   && [ "$(cat "$TMP/etc-na/server_ip")" = 192.0.2.31 ] && [ ! -e "$TMP/ni.log" ]; then
	ok "updating the active Naive link reloads only the Naive service"
else
	bad "reload-with ($o | $(tr '\n' ';' < "$D/order.log" 2>/dev/null))"
fi
# ON/OFF act on the active protocol's own steering table.
nreset; echo naive > "$D/proto"
nenv "$SH" off >/dev/null 2>&1; nenv "$SH" on >/dev/null 2>&1
if [ "$(tr '\n' ' ' < "$D/steer.log")" = "nv down nv up " ] && [ ! -e "$D/xrestart.log" ]; then ok "transparent on/off toggles only the active protocol's rules"; else bad "on/off ($(tr '\n' ' ' < "$D/steer.log" 2>/dev/null))"; fi
rm -f "$D/tproxy.disabled"
# Back to VLESS: Xray is regenerated and started, the other three are stopped.
nreset; echo hy2 > "$D/proto"
printf 'vless://11111111-2222-3333-4444-555555555555@192.0.2.10:443?security=none&type=tcp#t\n' > "$D/link.txt"
o=$(nenv "$SH" proto vless 2>&1 || true)
if [ "$o" = OK ] && [ "$(cat "$D/proto")" = vless ] && [ -s "$D/xrestart.log" ] \
   && grep -qx 'hysteria-client stop' "$TMP/ni.log" && grep -qx 'naive-client stop' "$TMP/ni.log" && grep -qx 'wireguard-client stop' "$TMP/ni.log" \
   && ! grep -qx 'xray-client stop' "$TMP/ni.log" && grep -qx 'xray-client enable' "$TMP/ni.log" && ! grep -qx 'xray-client disable' "$TMP/ni.log" \
   && grep -qx 'hy down' "$D/steer.log"; then
	ok "switching back to VLESS starts Xray and stops Hysteria, Naive and WireGuard"
else
	bad "back to vless ($o | $(tr '\n' ';' < "$TMP/ni.log" 2>/dev/null))"
fi
cp "$TMP/config.keep" "$D/config.json"; echo vless > "$D/proto"; rm -f "$TMP/wgup.state"
# xray-client init: Xray started by hand while another protocol is active must not steer traffic.
mkdir -p "$TMP/xi/etc"
sed "s#/etc/xray#$TMP/xi/etc#g; s#/usr/bin/xray#xray#" "$ROOT/files/etc/init.d/xray-client" | sed '1d' > "$TMP/xi/init.sh"
cat > "$TMP/xi/tproxy.sh" <<EOF
#!/bin/sh
echo "\$1" >> "$TMP/xi/tp.log"
EOF
chmod 755 "$TMP/xi/tproxy.sh"; cp "$TMP/xi/tproxy.sh" "$TMP/xi/etc/tproxy.sh"
xi() { rm -f "$TMP/xi/tp.log" "$TMP/xi/etc/tproxy.disabled"; echo "$1" > "$TMP/xi/etc/proto"; ( procd_open_instance(){ :; }; procd_set_param(){ :; }; procd_close_instance(){ :; }; . "$TMP/xi/init.sh"; start_service ) ; cat "$TMP/xi/tp.log"; }
if [ "$(xi naive)" = down ] && [ "$(xi hy2)" = down ] && [ "$(xi wg)" = down ] && [ "$(xi vless)" = up ] && [ "$(xi socks)" = up ]; then
	ok "xray-client turns transparent mode on only while Xray is the active protocol"
else
	bad "xray-client tproxy guard ($(xi naive)/$(xi vless))"
fi
# Static checks: nothing native goes through Xray any more.
if ! grep -q 'freedom' "$SH" && ! grep -q 'hyup' "$SH" && ! grep -qi 'naiveproxy' "$CGI" "$SH"; then ok "no Xray freedom outbound, no Xray-side helper for the native protocols"; else bad "xray leftovers in vless.sh"; fi

# Service row: not installed / config not saved / running / not running, each with its button state.
wgrow() { # args: extra env... -> the WireGuard span and its button
	env PIDOF_UP=xray VLESS_AU_EGRESS="$TMP/hooks/egress-final.sh" VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_NAIVE_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/no-hysteria" REQUEST_METHOD=GET "$@" "$CGI" \
	| tr '\n' ' ' | sed 's/.*<span class=svc>\(<span[^>]*>WireGuard<\/span>.*\)/\1/' | cut -c1-520
}
wr1=$(wgrow)
mv "$D/wg.json" "$TMP/wg.json.keep"
wr2=$(wgrow VLESS_WG_BIN="$TMP/bin/wg-ok" VLESS_WG_SYSMOD="$TMP/wg-module")
mv "$TMP/wg.json.keep" "$D/wg.json"
wr3=$(wgrow VLESS_WG_BIN="$TMP/bin/wg-ok" VLESS_WG_SYSMOD="$TMP/wg-module")
: > "$TMP/wgup.state"
wr4=$(wgrow VLESS_WG_BIN="$TMP/bin/wg-ok" VLESS_WG_SYSMOD="$TMP/wg-module")
rm -f "$TMP/wgup.state"
if printf '%s' "$wr1" | grep -q 'color:#c62828;font-weight:700" title="not installed' && printf '%s' "$wr1" | grep -q 'class=rb disabled' \
   && printf '%s' "$wr2" | grep -q 'color:#c62828;font-weight:700" title="config not saved' && printf '%s' "$wr2" | grep -q 'class=rb disabled' \
   && printf '%s' "$wr3" | grep -q 'color:#777" title="stopped: not the active protocol' && ! printf '%s' "$wr3" | grep -q 'class=rb disabled' \
   && printf '%s' "$wr4" | grep -q 'color:#1a7f37" title="running' && ! printf '%s' "$wr4" | grep -q 'class=rb disabled'; then
	ok "the WireGuard row shows its real state: not installed, config not saved, idle (grey, not red), running"
else
	bad "wg row ($wr1 | $wr2 | $wr3 | $wr4)"
fi
# The init script itself, with stubbed ip / wg / nslookup: commands, config handed to wg, DNS fallback.
INIT_WG=$ROOT/files/etc/init.d/wireguard-client
mkdir -p "$TMP/wgi"
cat > "$TMP/wgi/ip" <<EOF
#!/bin/sh
echo "ip \$*" >> "$TMP/wgi/calls.log"
[ -n "\${IP_FAIL:-}" ] && case "\$*" in *"\$IP_FAIL"*) exit 1;; esac
exit 0
EOF
cat > "$TMP/wgi/wg" <<EOF
#!/bin/sh
echo "wg \$*" >> "$TMP/wgi/calls.log"
cat > "$TMP/wgi/setconf.txt"
exit 0
EOF
cat > "$TMP/wgi/nslookup" <<EOF
#!/bin/sh
[ -n "\${NS_FAIL:-}" ] && exit 1
printf 'Server: 127.0.0.1\nAddress: 127.0.0.1#53\n\nName: \$1\nAddress: 203.0.113.77\n'
EOF
chmod 755 "$TMP/wgi/ip" "$TMP/wgi/wg" "$TMP/wgi/nslookup"
wgi() { env PATH="$TMP/wgi:$PATH" AURORA_WG_JSON="$TMP/wgi/wg.json" AURORA_WG_CACHE="$TMP/wgi/wg.resolved" "$@" sh -c ". '$INIT_WG'; start"; }
echo '{"protocol":"wireguard","settings":{"secretKey":"SECRETKEY","address":["10.0.0.2/32"],"mtu":1380,"peers":[{"publicKey":"PUBKEY","preSharedKey":"PSK","endpoint":"vpn.example:51820","allowedIPs":["0.0.0.0/0"]}]}}' > "$TMP/wgi/wg.json"
rm -f "$TMP/wgi/calls.log" "$TMP/wgi/wg.resolved"
rc1=0; wgi >/dev/null 2>&1 || rc1=$?
c=$(cat "$TMP/wgi/calls.log")
if [ $rc1 = 0 ] \
   && printf '%s\n' "$c" | grep -qx 'ip link add wg-aurora type wireguard' \
   && printf '%s\n' "$c" | grep -qx 'wg setconf wg-aurora /dev/stdin' \
   && grep -qx 'PrivateKey = SECRETKEY' "$TMP/wgi/setconf.txt" && grep -qx 'PublicKey = PUBKEY' "$TMP/wgi/setconf.txt" \
   && grep -qx 'PresharedKey = PSK' "$TMP/wgi/setconf.txt" && grep -qx 'Endpoint = 203.0.113.77:51820' "$TMP/wgi/setconf.txt" \
   && grep -qx 'AllowedIPs = 0.0.0.0/0' "$TMP/wgi/setconf.txt" \
   && printf '%s\n' "$c" | grep -qx 'ip address add 10.0.0.2/32 dev wg-aurora' \
   && printf '%s\n' "$c" | grep -qx 'ip link set dev wg-aurora mtu 1380 up' \
   && printf '%s\n' "$c" | grep -qx 'ip route replace default dev wg-aurora table 871' \
   && printf '%s\n' "$c" | grep -qx 'ip rule add oif wg-aurora lookup 871 pref 871' \
   && ! printf '%s\n' "$c" | grep -q 'ip route.* table main\|ip route add default dev wg-aurora$' \
   && grep -qx 'vpn.example 203.0.113.77' "$TMP/wgi/wg.resolved"; then
	ok "wireguard-client builds wg-aurora from wg.json: setconf, address, MTU, policy route, no main-table change"
else
	bad "wireguard-client start (rc=$rc1: $(tr '\n' ';' < "$TMP/wgi/calls.log"))"
fi
# DNS down: the cached endpoint address is used; no cache and no DNS: a clear error and a clean-up.
rm -f "$TMP/wgi/calls.log"
rc2=0; wgi env NS_FAIL=1 >/dev/null 2>&1 || rc2=$?
rm -f "$TMP/wgi/wg.resolved" "$TMP/wgi/calls.log"
rc3=0; msg=$(wgi env NS_FAIL=1 2>&1) || rc3=$?
if [ $rc2 = 0 ] && grep -qx 'Endpoint = 203.0.113.77:51820' "$TMP/wgi/setconf.txt" \
   && [ $rc3 != 0 ] && printf '%s' "$msg" | grep -q 'cannot resolve the WireGuard endpoint vpn.example:51820' \
   && grep -qx 'ip link del wg-aurora' "$TMP/wgi/calls.log"; then
	ok "wireguard-client falls back to the cached endpoint address and cleans up when it cannot resolve"
else
	bad "wireguard-client dns (rc2=$rc2 rc3=$rc3 msg=$msg)"
fi
# Missing config, or no ip-full (rule fails): error text and the interface is removed again.
mv "$TMP/wgi/wg.json" "$TMP/wgi/wg.json.keep"
rc4=0; msg1=$(wgi 2>&1) || rc4=$?
mv "$TMP/wgi/wg.json.keep" "$TMP/wgi/wg.json"
rm -f "$TMP/wgi/calls.log"
rc5=0; msg2=$(wgi env IP_FAIL="rule add" 2>&1) || rc5=$?
if [ $rc4 != 0 ] && printf '%s' "$msg1" | grep -q 'WireGuard config is not saved' \
   && [ $rc5 != 0 ] && printf '%s' "$msg2" | grep -q 'ip-full is required' && grep -qx 'ip link del wg-aurora' "$TMP/wgi/calls.log"; then
	ok "wireguard-client reports a missing config or ip-full and removes the half-built interface"
else
	bad "wireguard-client errors ($msg1 | $msg2)"
fi

rm -f /tmp/xray-restart.err /tmp/vless.err

rm -f /tmp/xray-restart.err /tmp/aurora-restart-hysteria-client.err /tmp/aurora-restart-naive-client.err /tmp/vless.err

# --- Transparent mode status is honest: ENABLED only when traffic really passes ---
cat > "$TMP/hooks/health-ok.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMP/hooks/health-bad.sh" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$TMP/hooks/health-ok.sh" "$TMP/hooks/health-bad.sh"
hrow() { # $1 up-list $2 proto $3 probe-hook $4 NFT_FAIL -> rendered page
	echo "$2" > "$D/proto"
	rm -f "$TMP/health.cache"
	env PIDOF_UP="$1" NFT_FAIL="${4:-}" VLESS_AU_PROBE="$3" VLESS_HEALTH_CACHE="$TMP/health.cache" VLESS_AU_EGRESS="$TMP/hooks/egress-final.sh" \
		VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_NAIVE_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/bin/xray-ok" REQUEST_METHOD=GET "$CGI"
}
tm() { printf '%s\n' "$1" | sed -n 's/.*<tr><td>Transparent mode for the network:<\/td><td><b style="color:\([^"]*\)">\(.*\)<\/b><\/td><\/tr>.*/\1 \2/p' | head -1; }
h_ok=$(hrow naive naive "$TMP/hooks/health-ok.sh")
h_bad=$(hrow naive naive "$TMP/hooks/health-bad.sh")
h_down=$(hrow xray naive "$TMP/hooks/health-ok.sh")
h_off=$(hrow naive naive "$TMP/hooks/health-ok.sh" 1)
h_hy=$(hrow hysteria hy2 "$TMP/hooks/health-bad.sh")
h_vl=$(hrow xray vless "$TMP/hooks/health-ok.sh")
if [ "$(tm "$h_ok")" = "#1a7f37 ENABLED" ] && [ "$(tm "$h_vl")" = "#1a7f37 ENABLED" ] \
   && ! printf '%s' "$h_ok" | grep -q '<div class=banner>'; then
	ok "transparent mode is green ENABLED when the active protocol passes traffic (Naive, VLESS), no banner"
else
	bad "transparent mode ENABLED ($(tm "$h_ok") | $(tm "$h_vl"))"
fi
if [ "$(tm "$h_bad")" = "#c62828 ERROR" ] && printf '%s' "$h_bad" | grep -q '<div class=banner>' \
   && printf '%s' "$h_bad" | grep -q 'NAIVE IS RUNNING BUT NO TRAFFIC PASSES THROUGH THE SERVER' \
   && printf '%s' "$h_bad" | grep -q 'CHECK THE SERVER, THE PORT AND THE LOGIN AND PASSWORD'; then
	ok "running but not passing traffic: red ERROR plus a banner with the cause and the fix"
else
	bad "transparent mode ERROR (broken) ($(tm "$h_bad"))"
fi
if [ "$(tm "$h_down")" = "#c62828 ERROR" ] && printf '%s' "$h_down" | grep -q 'NAIVE IS NOT RUNNING' \
   && printf '%s' "$h_hy" | grep -q 'HYSTERIA USES UDP'; then
	ok "steering on but the service is not running: red ERROR with banner; Hysteria banner mentions blocked UDP"
else
	bad "transparent mode ERROR (down) ($(tm "$h_down"))"
fi
if [ "$(tm "$h_off")" = "#c62828 DISABLED (direct internet)" ] && ! printf '%s' "$h_off" | grep -q '<div class=banner>'; then
	ok "steering off: red DISABLED, no banner"
else
	bad "transparent mode DISABLED ($(tm "$h_off"))"
fi
# health command: off / down / ok / broken, and a 20 s cache
ch() { env PIDOF_UP="$1" NFT_FAIL="${3:-}" VLESS_AU_PROBE="$2" VLESS_HEALTH_CACHE="$TMP/health.cache" "$SH" health; }
echo naive > "$D/proto"; rm -f "$TMP/health.cache"
c1=$(ch naive "$TMP/hooks/health-ok.sh" 1); c2=$(ch xray "$TMP/hooks/health-ok.sh"); c3=$(ch naive "$TMP/hooks/health-bad.sh"); rm -f "$TMP/health.cache"
c4=$(ch naive "$TMP/hooks/health-ok.sh"); c5=$(ch naive "$TMP/hooks/health-bad.sh")
if [ "$c1" = off ] && [ "$c2" = down ] && [ "$c3" = broken ] && [ "$c4" = ok ] && [ "$c5" = ok ]; then
	ok "vless.sh health: off, down, broken, ok, and the answer is cached"
else
	bad "health command ($c1 $c2 $c3 $c4 $c5)"
fi
# The Test button uses the ACTIVE protocol's own entry, not a fixed Xray SOCKS port.
cat > "$TMP/bin/curl" <<EOF
#!/bin/sh
echo "\$*" >> "$TMP/curl.log"
case "\$*" in *generate_204*) printf '204 0.100';; *ipify*) printf '185.167.97.143';; *youtube*) printf '200';; *speed.cloudflare*) printf '5000000 50000000';; esac
EOF
chmod 755 "$TMP/bin/curl"
pe=""
for pr in vless naive hy2; do
	echo "$pr" > "$D/proto"; : > "$TMP/curl.log"
	body="action=test"
	out=$(printf '%s' "$body" | env PIDOF_UP=xray VLESS_AU_PROBE="$TMP/hooks/health-ok.sh" VLESS_HEALTH_CACHE="$TMP/health.cache" VLESS_AU_EGRESS="$TMP/hooks/egress-final.sh" \
		VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_NAIVE_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/bin/xray-ok" REQUEST_METHOD=POST CONTENT_LENGTH=${#body} "$CGI")
	case "$pr" in vless) port=10808;; naive) port=10828;; hy2) port=10818;; esac
	others=$(grep -o '127.0.0.1:1[0-9]*' "$TMP/curl.log" | grep -v "127.0.0.1:$port\$" || true)
	if grep -q "127.0.0.1:$port " "$TMP/curl.log" && [ -z "$others" ] && printf '%s' "$out" | grep -q 'Test: connected'; then :; else pe="$pe $pr"; fi
done
rm -f "$TMP/bin/curl"
if [ -z "$pe" ]; then ok "the Test button goes through the active protocol's own entry (10808 / 10828 / 10818)"; else bad "test entry for:$pe"; fi
if ! grep -q 'socks5-hostname 127.0.0.1:1' "$CGI"; then ok "the CGI no longer runs curl against a fixed Xray SOCKS port"; else bad "CGI still has a hard-coded curl SOCKS entry"; fi
echo vless > "$D/proto"


# --- Install buttons (one per VPN client), in the middle of the page ---
ihtml=$(render xray 0 "$TMP/hooks/egress-final.sh")
nb=$(printf '%s' "$ihtml" | grep -o 'class=ib data-p=[a-z0-9]*[^>]*>Install [A-Za-z0-9 ]*<' | sed 's/.*>\(Install [^<]*\)</\1/')
if [ "$nb" = "Install VLESS
Install Hysteria 2
Install Naive
Install WireGuard" ] && ! printf '%s' "$ihtml" | grep -q 'Install VLESS (Xray)'; then
	ok "four install buttons: Install VLESS, Install Hysteria 2, Install Naive, Install WireGuard"
else
	bad "install button labels: $nb"
fi
pos_act=$(printf '%s' "$ihtml" | grep -n 'name=action value=speed' | head -1 | cut -d: -f1)
pos_ins=$(printf '%s' "$ihtml" | grep -n 'id=install' | head -1 | cut -d: -f1)
pos_vpn=$(printf '%s' "$ihtml" | grep -n '<h3>VPN</h3>' | head -1 | cut -d: -f1)
if [ -n "$pos_act" ] && [ -n "$pos_ins" ] && [ -n "$pos_vpn" ] && [ "$pos_act" -lt "$pos_ins" ] && [ "$pos_ins" -lt "$pos_vpn" ]; then
	ok "the install block sits between the action buttons and the VPN cards (middle of the page)"
else
	bad "install block position act=$pos_act ins=$pos_ins vpn=$pos_vpn"
fi
if [ "$(printf '%s' "$ihtml" | grep -c 'class=ibar')" = 4 ] && [ "$(printf '%s' "$ihtml" | grep -c 'class=ipct')" = 4 ] \
   && printf '%s' "$ihtml" | grep -q "?install-status" && printf '%s' "$ihtml" | grep -q "fetch('?install'"; then
	ok "each button has a progress bar and a percent line, polled from ?install-status"
else
	bad "install progress elements"
fi
if ! printf '%s' "$ihtml" | grep -qi 'translat'; then ok "the page does not mention a translation"; else bad "page mentions translation"; fi

cat > "$TMP/hooks/ic-stub.sh" <<STUBEND
#!/bin/sh
echo "\$*" >> "$TMP/ic.log"
case "\$1" in
  status) printf '{"xray":{"proto":"xray","installed":true,"version":"9.9.9","state":"idle","percent":0,"stage":"","error":""}}';;
  start) echo "OK: installation of \$2 started";;
esac
STUBEND
chmod 755 "$TMP/hooks/ic-stub.sh"
rm -f "$TMP/ic.log"
st=$(env VLESS_INSTALL_CLIENT="$TMP/hooks/ic-stub.sh" VLESS_PANEL_DIR="$D" REQUEST_METHOD=GET QUERY_STRING=install-status "$CGI")
if printf '%s' "$st" | grep -q 'application/json' && printf '%s' "$st" | grep -q '"version":"9.9.9"' && grep -q '^status' "$TMP/ic.log"; then
	ok "GET ?install-status returns the installer's JSON"
else
	bad "install-status endpoint: $st"
fi
rm -f "$TMP/ic.log"
for c in xray hy2 naive wg; do
	body="client=$c"
	printf '%s' "$body" | env VLESS_INSTALL_CLIENT="$TMP/hooks/ic-stub.sh" VLESS_PANEL_DIR="$D" REQUEST_METHOD=POST QUERY_STRING=install CONTENT_LENGTH=${#body} "$CGI" >/dev/null
done
body='client=xray;touch /tmp/pwned'
bo=$(printf '%s' "$body" | env VLESS_INSTALL_CLIENT="$TMP/hooks/ic-stub.sh" VLESS_PANEL_DIR="$D" REQUEST_METHOD=POST QUERY_STRING=install CONTENT_LENGTH=${#body} "$CGI")
if [ "$(cat "$TMP/ic.log")" = "start xray
start hy2
start naive
start wg" ] && printf '%s' "$bo" | grep -q 'ERROR: unknown client'; then
	ok "POST ?install starts only the four known clients; anything else is refused"
else
	bad "install POST: $(cat "$TMP/ic.log") / $bo"
fi
rm -f "$TMP/hooks/ic-stub.sh"

# --- Install block shows only the clients that are not installed ---
if printf '%s' "$ihtml" | grep -q '<div class=isec id=install hidden>' \
   && printf '%s' "$ihtml" | grep -q "sec.parentNode.removeChild(sec)" \
   && printf '%s' "$ihtml" | grep -q "if(o&&o.installed&&st!=='running'&&st!=='error')" \
   && ! printf '%s' "$ihtml" | grep -qi 'reinstall'; then
	ok "the install block starts hidden, hides installed clients, and is removed when none is left"
else
	bad "install block hide logic missing"
fi
# Render the page in headless Chrome with a mocked ?install-status (skipped when there is no Chrome)
CHROME=""
for c in google-chrome chromium chromium-browser chrome; do command -v "$c" >/dev/null 2>&1 && { CHROME=$c; break; }; done
if [ -z "$CHROME" ]; then
	echo "SKIP: no headless Chrome, install-block render checks not run"
else
	mkdir -p "$TMP/rt"
	rpage() { # <js status expression> -> sets $rdom
		python3 - "$1" "$TMP/rt" <<'PYEND'
import sys
j,d=sys.argv[1],sys.argv[2]
h=sys.stdin.read() if False else open(d+'/page.html').read()
mock="<script>var __S=%s;window.fetch=function(u,o){var b=String(u).indexOf('?install-status')===0?JSON.stringify(typeof __S==='function'?__S():__S):'';return Promise.resolve({json:function(){return Promise.resolve(JSON.parse(b))},text:function(){return Promise.resolve(b)}})};</script>"%j
open(d+'/t.html','w').write(h.replace('<body>','<body>'+mock,1))
PYEND
		rdom=$("$CHROME" --headless=new --no-sandbox --disable-gpu --virtual-time-budget=${2:-6000} --dump-dom "file://$TMP/rt/t.html" 2>/dev/null)
	}
	printf '%s' "$ihtml" | sed '1,/^$/d' > "$TMP/rt/page.html"
	[ -s "$TMP/rt/page.html" ] || printf '%s' "$ihtml" > "$TMP/rt/page.html"
	I='{"installed":true,"version":"1","state":"idle","percent":0,"stage":"","error":""}'
	N='{"installed":false,"version":"","state":"idle","percent":0,"stage":"","error":""}'
	live() { printf '%s' "$rdom" | grep -o '<div class="c ic[^"]*" data-p="[a-z0-9]*"[^>]*>' | grep -v 'data-gone' | sed 's/.*data-p="\([a-z0-9]*\)".*/\1/' | tr '\n' ' '; }
	rpage "{xray:$I,hy2:$I,naive:$I,wg:$I}"
	if ! printf '%s' "$rdom" | grep -q 'id="install"' && ! printf '%s' "$rdom" | grep -q 'Install VPN clients'; then
		ok "render: all four installed -> the whole install block (heading, cards, hint) is absent"
	else bad "render all installed: block still there"; fi
	rpage "{xray:$I,hy2:$N,naive:$I,wg:$I}"
	if [ "$(live)" = "hy2 " ] && ! printf '%s' "$rdom" | grep -q 'id="install" hidden'; then
		ok "render: one client missing -> only its card is shown and the block is visible"
	else bad "render one missing: '$(live)'"; fi
	rpage "{xray:$N,hy2:$N,naive:$N,wg:$N}"
	if [ "$(live)" = "xray hy2 naive wg " ]; then ok "render: none installed -> all four cards"; else bad "render none installed: '$(live)'"; fi
	rpage "{xray:$I,hy2:$I,naive:{installed:false,missing:'dnsproxy',state:'idle',percent:0},wg:$I}"
	if [ "$(live)" = "naive " ] && printf '%s' "$rdom" | grep -q 'dnsproxy is missing'; then
		ok "render: Naive without dnsproxy counts as not installed"
	else bad "render naive half installed: '$(live)'"; fi
	rpage "{xray:$I,hy2:{installed:false,state:'error',percent:40,error:'checksum mismatch'},naive:$I,wg:$I}"
	if [ "$(live)" = "hy2 " ] && printf '%s' "$rdom" | grep -q 'Error: checksum mismatch'; then
		ok "render: a failed install keeps its card with the error"
	else bad "render error card: '$(live)'"; fi
	rpage "(function(){var n=0;return function(){n++;return {xray:$I,hy2:{installed:false,state:'running',percent:50,stage:'downloading'},naive:$I,wg:$I}}})()" 5000
	if [ "$(live)" = "hy2 " ] && printf '%s' "$rdom" | grep -q '50%'; then
		ok "render: a running install keeps its card with progress"
	else bad "render running card: '$(live)'"; fi
	rpage "(function(){var n=0;return function(){n++;return {xray:$I,hy2:n<3?{installed:false,state:'running',percent:50,stage:'downloading'}:{installed:true,version:'2',state:'done',percent:100,stage:'done'},naive:$I,wg:$I}}})()" 15000
	if ! printf '%s' "$rdom" | grep -q 'id="install"'; then
		ok "render: after the install reaches 100% its card and the empty block disappear"
	else bad "render running->done: block still there: '$(live)'"; fi
fi



if [ "$fail" -eq 0 ]; then
	echo "All panel UI tests passed."
else
	echo "$fail panel UI test(s) failed." >&2
	exit 1
fi
