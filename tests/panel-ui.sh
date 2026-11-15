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
echo "нет скрипта /etc/init.d/\$1" > /tmp/aurora-restart-\$1.err
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
unset VLESS_AU_PORTS_BUSY VLESS_AU_SVC_RESTART VLESS_AU_EGRESS VLESS_AU_SKIP_XRAY_TEST || true

run() {
	# shellcheck disable=SC2086
	env VLESS_XRAY_BIN="$1" VLESS_AU_XRESTART="$2" ${3:+VLESS_AU_SVC_RESTART="$3"} "$SH" restart 2>/dev/null
}

# --- version is the next round release ---
ver=$(sed -n 's/^Version: //p' "$ROOT/control/control" | head -1)
cls=$("$VC" classify "$ver")
if [ "$ver" = 1.4.0 ] && [ "$cls" = full ]; then
	ok "package version 1.4.0 is a full release"
else
	bad "version ($ver class=$cls)"
fi

# --- restart: missing binary, before any start ---
rm -f "$D/xrestart.log"
echo vless > "$D/proto"
out=$(env VLESS_XRAY_BIN="$TMP/no-such-xray" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: НЕТ ФАЙЛА' \
   && printf '%s\n' "$out" | grep -q '^HINT: УСТАНОВИТЕ XRAY' \
   && [ ! -s "$D/xrestart.log" ]; then
	ok "restart missing xray names the file and the install hint"
else
	bad "restart missing xray ($out)"
fi

# --- restart: config test failure is not a port or a generic start error ---
: > "$D/xrestart.log"
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-badcfg" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q 'XRAY ОТКЛОНИЛ КОНФИГ: FAILED TO PARSE CONFIG: INVALID OUTBOUND' \
   && printf '%s\n' "$out" | grep -q '^HINT: ИСПРАВЬТЕ КОНФИГ' \
   && ! grep -q ok "$D/xrestart.log"; then
	ok "restart reports a config-test failure and does not start xray"
else
	bad "restart bad config ($out)"
fi

# --- restart: permission denied from the config test ---
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-denied" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: НЕТ ПРАВ НА КОНФИГ' \
   && printf '%s\n' "$out" | grep -q '^HINT: ЗАПУСТИТЕ ПЕРЕЗАПУСК ОТ ROOT'; then
	ok "restart turns permission denied into a root/chmod hint"
else
	bad "restart permission ($out)"
fi

# --- restart: address already in use ---
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-eaddr.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: ПОРТ ЗАНЯТ:' \
   && printf '%s\n' "$out" | grep -q 'NETSTAT'; then
	ok "restart reports a busy port and how to free it"
else
	bad "restart eaddr ($out)"
fi

# --- restart: ports busy even without that phrase in the log ---
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-fail.sh" VLESS_AU_PORTS_BUSY=10808/TCP "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: ПОРТ ЗАНЯТ: 10808/TCP'; then
	ok "restart reports the hooked busy port"
else
	bad "restart ports hook ($out)"
fi

# --- restart: generic start failure keeps the raw log, uppercased ---
unset VLESS_AU_PORTS_BUSY
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-fail.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q 'XRAY НЕ ЗАПУСТИЛСЯ: STARTUP FAILED: BOOM' \
   && printf '%s\n' "$out" | grep -q '^HINT: ПОСМОТРИТЕ LOGREAD -E XRAY'; then
	ok "restart keeps the raw start error and a logread hint"
else
	bad "restart generic ($out)"
fi

# --- restart: permission denied from the init script, after a clean config test ---
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-denied.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: НЕТ ПРАВ НА ЗАПУСК XRAY' \
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
if printf '%s\n' "$out" | grep -q '^ERROR: НЕТ ФАЙЛА' \
   && printf '%s\n' "$out" | grep -q '^HINT: УСТАНОВИТЕ HYSTERIA' \
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
if printf '%s\n' "$out" | grep -q 'HYSTERIA НЕ ЗАПУСТИЛАСЬ: CLIENT.YAML: AUTH FAILED' \
   && printf '%s\n' "$out" | grep -q '/ETC/HYSTERIA/CLIENT.YAML'; then
	ok "hy2 restart surfaces the hysteria log and the yaml hint"
else
	bad "hy2 hysteria fail ($out)"
fi

out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_HYSTERIA_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" VLESS_AU_SVC_RESTART="$TMP/hooks/svc-noscript.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: НЕТ СКРИПТА /ETC/INIT.D/HYSTERIA-CLIENT' \
   && printf '%s\n' "$out" | grep -q 'ПЕРЕУСТАНОВИТЕ ПАКЕТ'; then
	ok "missing hysteria init script tells you to reinstall"
else
	bad "hy2 noscript ($out)"
fi

# --- naive ---
echo naive > "$D/proto"
out=$(env VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_NAIVE_BIN="$TMP/no-naive" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^HINT: УСТАНОВИТЕ NAIVE КОМАНДОЙ /USR/LIBEXEC/AURORA-PANEL/INSTALL-NAIVE.SH'; then
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
if printf '%s\n' "$out" | grep -q 'НЕТ ФАЙЛА КОНФИГА' \
   && printf '%s\n' "$out" | grep -q 'НАЖМИТЕ «ПОДКЛЮЧИТЬ»'; then
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
		REQUEST_METHOD=GET \
		"$CGI"
}

html=$(render xray 0 "$TMP/hooks/egress-final.sh")
ipget() { env PIDOF_UP="$1" VLESS_AU_EGRESS="$2" REQUEST_METHOD=GET QUERY_STRING=ip "$CGI"; }
row() { printf '%s\n' "$html" | sed -n "s/.*<tr><td>$1<\\/td><td>\\(.*\\)<\\/td><\\/tr>.*/\\1/p" | head -1; }
proto=$(row 'Протокол:')
exitrow=$(printf '%s\n' "$html" | grep '<td>IP выхода:</td>' | head -1)
svc=$(row 'Служба (демон):')
if printf '%s' "$proto" | grep -q '>Hysteria2<' \
   && printf '%s' "$exitrow" | grep -q 'id=egress' \
   && ! printf '%s' "$exitrow" | grep -q '192.0.2' \
   && printf '%s\n' "$html" | grep -q 'color:#1a7f37">Xray' \
   && printf '%s\n' "$html" | grep -q 'color:#c62828">Hysteria' \
   && printf '%s\n' "$html" | grep -q 'Перезапустить службу' \
   && printf '%s\n' "$html" | grep -q 'Xray</b> / <b style="color:#c62828">Hysteria' \
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
if ! env PIDOF_FILE="$TMP/pidof.state" sh "$TMP/ri.sh" crash-client crash && grep -q 'сразу завершился' /tmp/aurora-restart-crash-client.err; then
	ok "restart_init rejects a daemon that dies right after start"
else
	bad "restart_init crash"
fi
rm -f /tmp/aurora-restart-good-client.err /tmp/aurora-restart-crash-client.err "$TMP/ri.sh"

# Transparent mode must be up after a restart (unless switched off).
rm -f "$D/tproxy.disabled"
out=$(env NFT_FAIL=1 VLESS_XRAY_BIN="$TMP/bin/xray-ok" VLESS_AU_XRESTART="$TMP/hooks/xrestart-ok.sh" "$SH" restart 2>/dev/null || true)
if printf '%s\n' "$out" | grep -q '^ERROR: ПРОЗРАЧНЫЙ РЕЖИМ НЕ ВКЛЮЧИЛСЯ' \
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
   && printf '%s\n' "$html" | grep -q '>Добавить SOCKS5<' \
   && printf '%s\n' "$html" | grep -q 'id=card-http>' \
   && ! printf '%s\n' "$html" | grep -q 'id=card-http hidden' \
   && printf '%s\n' "$html" | grep -q 'value="proxy.example"' \
   && printf '%s\n' "$html" | grep -q 'IPv6 не проксируется.' \
   && printf '%s\n' "$html" | grep -q 'Локальные прокси для отдельных программ'; then
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
   && ! printf '%s\n' "$html3" | sed -n 's/.*<tr><td>Протокол:<\/td><td>\(.*\)<\/td><\/tr>.*/\1/p' | grep -q 'VLESS'; then
	ok "protocol row follows a connected SOCKS5 upstream"
else
	bad "socks protocol row"
fi
rm -f "$D/socks.json"
echo hy2 > "$D/proto"

# Restart failure banner is the first body content, reason red, fix green.
body='action=restart'
html4=$(printf '%s' "$body" | env PIDOF_UP=xray VLESS_XRAY_BIN="$TMP/no-such-xray" \
	REQUEST_METHOD=POST CONTENT_LENGTH=${#body} "$CGI")
# Banner before the title, and no yellow duplicate of the same error.
if printf '%s\n' "$html4" | tr '\n' ' ' | grep -q '<body> *<div class=banner><div class=why>НЕТ ФАЙЛА' \
   && printf '%s\n' "$html4" | grep -q 'class=why' \
   && printf '%s\n' "$html4" | grep -q 'class=how' \
   && printf '%s\n' "$html4" | grep -q 'УСТАНОВИТЕ XRAY' \
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

rm -f /tmp/xray-restart.err /tmp/aurora-restart-hysteria-client.err /tmp/aurora-restart-naive-client.err /tmp/vless.err

if [ "$fail" -eq 0 ]; then
	echo "All panel UI tests passed."
else
	echo "$fail panel UI test(s) failed." >&2
	exit 1
fi
