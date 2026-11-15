#!/bin/sh
# Status card, restart failures, egress IP and the VPN/proxy page.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SH=$ROOT/files/etc/xray/vless.sh
CGI=$ROOT/files/www-aurora/cgi-bin/vless
LIB=$ROOT/files/usr/libexec/aurora-panel/autoupdate-lib.sh
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
if [ "$ver" = 1.5.0a1 ] && [ "$cls" = pre ]; then
	ok "package version 1.5.0a1 is a pre-release"
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
if printf '%s\n' "$out" | grep -q '^HINT: INSTALL NAIVE WITH /USR/LIBEXEC/AURORA-PANEL/INSTALL-NAIVE.SH'; then
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
g1=$(env VLESS_AU_EGRESS_CACHE="$TMP/egress.cache" "$SH" egress 2>/dev/null || true)
g2=$(env VLESS_AU_EGRESS_CACHE="$TMP/egress.cache" "$SH" egress 2>/dev/null || true)
n=$(wc -l < "$TMP/curl.count" | tr -d ' ')
if [ "$g1" = 203.0.113.9 ] && [ "$g2" = 203.0.113.9 ] && [ "$n" = 1 ] \
   && grep -q -- '-m 3 ' "$SH"; then
	ok "egress is one 3 s probe, then served from the 60 s cache"
else
	bad "egress cache g1=$g1 g2=$g2 curls=$n"
fi
echo vless > "$D/proto"
env VLESS_AU_EGRESS_CACHE="$TMP/egress.cache" "$SH" egress >/dev/null 2>&1 || true
n=$(wc -l < "$TMP/curl.count" | tr -d ' ')
echo hy2 > "$D/proto"
if [ "$n" = 2 ]; then ok "egress cache is dropped when the protocol changes"; else bad "egress cache key (curls=$n)"; fi

# --- restart order, stability and tproxy ---
echo hy2 > "$D/proto"
rm -f "$D/order.log" "$D/svc.log" "$D/xrestart.log"
env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" VLESS_AU_SVC_RESTART="$TMP/hooks/svc-ok.sh" "$SH" restart >/dev/null 2>&1 || true
if [ "$(tr '\n' ' ' < "$D/order.log")" = "hysteria-client xray " ]; then
	ok "restart brings Hysteria up before Xray"
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
echo wg > "$D/proto"
o4=$(svcenv env VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" "$SH" restart-svc wireguard 2>/dev/null || true)
echo vless > "$D/proto"
o5=$(svcenv env NFT_FAIL=1 VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" "$SH" restart-svc xray 2>/dev/null || true)
o6=$(svcenv "$SH" restart-svc bogus 2>/dev/null || true)
if [ "$o3" = OK ] && [ "$o4" = OK ] && [ "$(wc -l < "$D/xrestart.log" | tr -d ' ')" -ge 2 ] \
   && printf '%s\n' "$o5" | grep -q '^ERROR: TRANSPARENT MODE IS NOT ACTIVE' \
   && printf '%s\n' "$o6" | grep -q '^ERROR: UNKNOWN SERVICE'; then
	ok "xray and wireguard restart xray and check nft; unknown names are rejected"
else
	bad "svc xray/wg ($o3/$o4/$o5/$o6)"
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

# WireGuard that is not the connected protocol: Xray is not touched at all.
reset_x 0
echo vless > "$D/proto"
o=$(xenv "$SH" restart-svc wireguard 2>/dev/null || true)
if printf '%s\n' "$o" | grep -q '^ERROR: WIREGUARD (RUNS INSIDE XRAY): WIREGUARD IS NOT CONNECTED' \
   && [ ! -e "$TMP/xinit.log" ] && [ ! -e "$D/tproxy.log" ] && [ ! -e "$D/recover.log" ]; then
	ok "restarting an inactive WireGuard does not touch Xray or transparent mode"
else
	bad "wg inactive ($o)"
fi
# Active WireGuard: the banner names the pressed service, then the real reason.
reset_x 99
echo wg > "$D/proto"
o=$(xenv VLESS_AU_XRESTART_MAX=2 "$SH" restart-svc wireguard 2>/dev/null || true)
echo vless > "$D/proto"
if printf '%s\n' "$o" | grep -q '^ERROR: WIREGUARD (RUNS INSIDE XRAY): PORT IN USE: 12346/TCP'; then
	ok "a WireGuard restart failure names WireGuard and the concrete reason"
else
	bad "wg banner ($o)"
fi
# The WireGuard button is disabled unless WireGuard is the connected protocol.
htmlw=$(render xray 0 "$TMP/hooks/egress-final.sh")
echo wg > "$D/proto"; echo '{}' > "$D/wg.json"
htmlw2=$(render xray 0 "$TMP/hooks/egress-final.sh")
echo vless > "$D/proto"; rm -f "$D/wg.json"
if printf '%s\n' "$htmlw" | grep -q 'name=svc value=wireguard><button type=submit class=rb disabled' \
   && ! printf '%s\n' "$htmlw2" | grep -q 'name=svc value=wireguard><button type=submit class=rb disabled' \
   && grep -q 'button.rb:disabled' "$CGI"; then
	ok "the WireGuard restart button is disabled unless WireGuard is connected"
else
	bad "wg button disabled state"
fi
rm -f /tmp/xray-restart.err /tmp/vless.err

rm -f /tmp/xray-restart.err /tmp/aurora-restart-hysteria-client.err /tmp/aurora-restart-naive-client.err /tmp/vless.err

if [ "$fail" -eq 0 ]; then
	echo "All panel UI tests passed."
else
	echo "$fail panel UI test(s) failed." >&2
	exit 1
fi
