#!/bin/sh
# Local tests for autoupdate helpers and vless.sh update (mocked tree, no router).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=$ROOT/files/usr/libexec/aurora-panel/autoupdate-lib.sh
SH=$ROOT/files/etc/xray/vless.sh
fail=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export VLESS_PANEL_DIR=$TMP/etc/xray
export VLESS_HYSTERIA_DIR=$TMP/etc/hysteria
export VLESS_NAIVE_DIR=$TMP/etc/naive
export VLESS_AU_LIB=$LIB
export VLESS_AU_CRON=$TMP/crontabs/root
export VLESS_AU_RUN=$ROOT/files/usr/libexec/aurora-panel/autoupdate-run.sh
export VLESS_SH=$SH
export D=$VLESS_PANEL_DIR
export HYD=$VLESS_HYSTERIA_DIR
export NAD=$VLESS_NAIVE_DIR
# shellcheck disable=SC1090
. "$LIB"

mkdir -p "$D" "$HYD" "$NAD" "$AU_DIR" "$(dirname "$AU_CRON")"
# Fake current configs (not real credentials).
printf 'vless://00000000-0000-0000-0000-000000000000@192.0.2.10:443?sni=example.com\n' > "$D/link.txt"
printf 'hysteria2://testpass@192.0.2.10:443?sni=example.com\n' > "$D/hy2.txt"
printf 'naive+https://user:pass@192.0.2.10:8445\n' > "$D/naive.txt"
cat > "$D/wg.conf" <<'WG'
[Interface]
PrivateKey = TESTPRIVATEKEY
Address = 10.0.0.2/32

[Peer]
PublicKey = TESTPUBLICKEY
Endpoint = 192.0.2.10:51820
AllowedIPs = 0.0.0.0/0
WG
echo vless > "$D/proto"
echo ru > "$D/mode"
echo 192.0.2.10 > "$D/server_ip"
echo '{}' > "$D/config.json"

# --- extract: raw vless, pick first of scheme from a mixed list ---
cat > "$TMP/raw.txt" <<'IN'
vmess://aaaa
vless://11111111-1111-1111-1111-111111111111@192.0.2.20:443?sni=a.example
ss://bbbb
vless://22222222-2222-2222-2222-222222222222@192.0.2.21:443
IN
if au_extract "$TMP/raw.txt" vless "$TMP/out.txt" \
   && grep -q 'vless://11111111-1111-1111-1111-111111111111@192.0.2.20:443' "$TMP/out.txt"; then
	ok "extract first raw vless"
else
	bad "extract first raw vless ($(cat "$TMP/out.txt" 2>/dev/null))"
fi

# --- extract: hysteria2 and hy2 ---
echo 'hy2://pw@192.0.2.30:443?sni=h.example' > "$TMP/raw.txt"
if au_extract "$TMP/raw.txt" hy2 "$TMP/out.txt" && grep -q 'hy2://pw@192.0.2.30:443' "$TMP/out.txt"; then
	ok "extract raw hy2"
else
	bad "extract raw hy2"
fi

# --- extract: naive ---
echo 'naive+https://u:p@192.0.2.40:8445' > "$TMP/raw.txt"
if au_extract "$TMP/raw.txt" naive "$TMP/out.txt" && grep -q 'naive+https://u:p@192.0.2.40:8445' "$TMP/out.txt"; then
	ok "extract raw naive"
else
	bad "extract raw naive"
fi

# --- extract: wireguard conf ---
cp "$D/wg.conf" "$TMP/raw.txt"
if au_extract "$TMP/raw.txt" wg "$TMP/out.txt" && grep -q '\[Interface\]' "$TMP/out.txt"; then
	ok "extract raw wg conf"
else
	bad "extract raw wg conf"
fi

# --- extract: base64 subscription ---
{ printf 'ss://xx\nvless://aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa@192.0.2.50:443?sni=b.example\nhysteria2://pw@192.0.2.50:443\n' | base64 | tr -d '\n'; echo; } > "$TMP/raw.txt"
if au_extract "$TMP/raw.txt" vless "$TMP/out.txt" \
   && grep -q 'vless://aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa@192.0.2.50:443' "$TMP/out.txt"; then
	ok "extract base64 subscription vless"
else
	bad "extract base64 subscription vless ($(cat "$TMP/out.txt" 2>/dev/null))"
fi
if au_extract "$TMP/raw.txt" hy2 "$TMP/out.txt" && grep -q 'hysteria2://pw@192.0.2.50:443' "$TMP/out.txt"; then
	ok "extract base64 subscription hy2"
else
	bad "extract base64 subscription hy2"
fi

# --- extract: garbage ---
echo 'hello world' > "$TMP/raw.txt"
if au_extract "$TMP/raw.txt" vless "$TMP/out.txt"; then
	bad "extract should fail on garbage"
else
	ok "extract fails on garbage"
fi

# --- save/load roundtrip (no URL is stored in the conf any more) ---
au_save_conf vless 1 6h
au_load vless
if [ "$AU_ENABLED" = 1 ] && [ "$AU_INTERVAL" = 6h ]; then
	ok "au_save_conf/au_load roundtrip"
else
	bad "au_save_conf/au_load"
fi
if grep -q '^url=' "$AU_DIR/vless.conf"; then bad "conf must not contain url="; else ok "conf has no url= line"; fi
if au_save_conf vless 1 'https://x' 1h 2>/dev/null; then bad "old 4-argument form must be rejected"; else ok "au_save_conf rejects a bad interval"; fi
# legacy conf lines (source=, url=) are ignored and never expanded as shell
printf 'enabled=1\nsource=server\nurl=$(echo pwned)\ninterval=1h\n' > "$AU_DIR/vless.conf"
au_load vless
if [ "$AU_ENABLED" = 1 ] && [ "$AU_INTERVAL" = 1h ] && [ -z "${AU_URL:-}" ]; then
	ok "au_load ignores legacy source=/url= lines"
else
	bad "au_load legacy lines ($AU_ENABLED $AU_INTERVAL ${AU_URL:-})"
fi

# --- resolve: only the protocol's own saved connection link is used ---
rm -f "$(au_src_file vless)"
if [ -z "$(au_resolve_url vless)" ]; then
	ok "resolve: saved vless:// link gives no URL"
else
	bad "resolve vless:// ($(au_resolve_url vless))"
fi
cp "$D/link.txt" "$TMP/link.keep"
printf 'https://example.com/own-sub\n' > "$D/link.txt"
if [ "$(au_resolve_url vless)" = "https://example.com/own-sub" ]; then
	ok "resolve: saved http(s) link is the source"
else
	bad "resolve saved http link ($(au_resolve_url vless))"
fi
cp "$TMP/link.keep" "$D/link.txt"
au_src_set vless 'https://example.com/field'
if [ "$(au_resolve_url vless)" = "https://example.com/field" ] && [ "$(stat -c %a "$(au_src_file vless)")" = 600 ]; then
	ok "resolve: subscription URL saved from the card (mode 600)"
else
	bad "resolve src ($(au_resolve_url vless))"
fi
au_src_clear vless
if [ -z "$(au_resolve_url vless)" ]; then ok "au_src_clear"; else bad "au_src_clear"; fi
if grep -rq 'autoupdate-server\|нашего сервера\|с нашего' "$ROOT/files" "$ROOT/README.md"; then
	bad "leftover references to the removed server source"
else
	ok "no references to the removed server source"
fi
# the page has no URL field, hint, or Save button any more
CGI=$ROOT/files/www-aurora/cgi-bin/vless
if grep -q 'auurl\|ссылка на обновление\|Пусто — обновление\|>Сохранить<' "$CGI"; then
	bad "CGI still has the auto-update URL field, hint or Save button"
else
	ok "CGI has no auto-update URL field, hint or Save button"
fi
if [ "$(grep -c '>Обновить сейчас<' "$CGI")" = 4 ] && [ "$(grep -c '>Подключить ' "$CGI")" = 6 ]; then
	ok "CGI has Connect on 6 cards and Update now on the 4 VPN cards"
else
	bad "CGI button count"
fi
if [ "$(grep -c 'link_field ' "$CGI")" = 4 ] \
   && grep -q 'type=button class=add' "$CGI" \
   && grep -q '>Добавить<' "$CGI" \
   && grep -q 'function fit(' "$CGI" \
   && grep -q 'overflow:hidden' "$CGI" \
   && ! grep -q 'textarea{[^}]*[^-]height:[0-9]' "$CGI"; then
	ok "CGI auto-expands link fields and has Add when empty"
else
	bad "CGI link field UI (Add button / auto-expand)"
fi
if grep -q '<h3>VPN</h3>' "$CGI" \
   && grep -q '<h3>Прокси</h3>' "$CGI" \
   && [ "$(grep -c 'class=sec' "$CGI")" = 2 ] \
   && [ "$(grep -c 'class=col' "$CGI")" = 2 ] \
   && grep -q '192.168.8.1:10808' "$CGI" \
   && grep -q '192.168.8.1:10809' "$CGI" \
   && grep -q '>SOCKS5<' "$CGI" \
   && grep -q '>HTTP<' "$CGI" \
   && grep -q 'IPv6 не проксируется.' "$CGI" \
   && grep -q 'Локальные прокси для отдельных программ' "$CGI" \
   && grep -q '>Подключить SOCKS5<' "$CGI" \
   && grep -q '>Подключить HTTP<' "$CGI" \
   && grep -q 'name=addr' "$CGI" \
   && grep -q 'name=port' "$CGI" \
   && grep -q 'name=user' "$CGI" \
   && grep -q 'name=pass' "$CGI" \
   && grep -q 'не проверять сертификат' "$CGI" \
   && grep -q 'name=tls' "$CGI" \
   && grep -q 'name=sni' "$CGI" \
   && grep -q 'sockssave' "$CGI" \
   && grep -q 'httpsave' "$CGI" \
   && grep -q 'proxy_fields' "$CGI" \
   && ! grep -q 'Для ручной настройки отдельных программ' "$CGI" \
   && ! grep -q 'Прокси для отдельных программ' "$CGI" \
   && ! grep -q 'column-count' "$CGI" \
   && ! grep -q 'Ссылка socks5' "$CGI" \
   && ! grep -q 'au_row socks' "$CGI" \
   && ! grep -q 'au_row http' "$CGI"; then
	ok "CGI has VPN and Proxy sections, aligned two-column grid"
else
	bad "CGI VPN/Proxy section layout"
fi

# --- interval / stamp ---
au_save_conf hy2 1 1h
now=1000000
rm -f "$(au_stamp_file hy2)"
if au_due hy2 "$now"; then ok "due when no stamp"; else bad "due when no stamp"; fi
au_stamp hy2 "$now"
if au_due hy2 $((now + 3599)); then bad "not due before 1h"; else ok "not due before 1h"; fi
if au_due hy2 $((now + 3600)); then ok "due after 1h"; else bad "due after 1h"; fi
au_save_conf hy2 0 1h
if au_due hy2 $((now + 99999)); then bad "disabled is not due"; else ok "disabled is not due"; fi

# --- same/norm ---
printf 'vless://abc@x\n' > "$TMP/a"
printf 'vless://abc@x\r\n' > "$TMP/b"
if au_same vless "$TMP/a" "$TMP/b"; then ok "link compare ignores CR/newline"; else bad "link compare"; fi
printf 'vless://abc@y\n' > "$TMP/b"
if au_same vless "$TMP/a" "$TMP/b"; then bad "link compare should differ"; else ok "link compare detects change"; fi

# --- cron install is idempotent ---
rm -f "$AU_CRON"
: > "$AU_CRON"
# skip init.d cron by setting IPKG_INSTROOT
IPKG_INSTROOT=/tmp au_cron_install
IPKG_INSTROOT=/tmp au_cron_install
n=$(grep -c "$AU_CRON_MARK" "$AU_CRON" || true)
if [ "$n" = 1 ] && grep -q 'autoupdate-run.sh' "$AU_CRON"; then
	ok "cron install idempotent"
else
	bad "cron install (lines=$n)"
fi
IPKG_INSTROOT=/tmp au_cron_remove
if grep -q "$AU_CRON_MARK" "$AU_CRON"; then
	bad "cron remove"
else
	ok "cron remove"
fi
IPKG_INSTROOT=/tmp au_cron_remove
ok "cron remove idempotent"

# legacy cron line from the old vless-router-panel package is replaced
printf '0 * * * * /usr/libexec/vless-panel/autoupdate-run.sh # vless-router-panel-autoupdate\n' > "$AU_CRON"
IPKG_INSTROOT=/tmp au_cron_install
if ! grep -q 'vless-router-panel-autoupdate' "$AU_CRON" && [ "$(grep -c "$AU_CRON_MARK" "$AU_CRON")" = 1 ]; then
	ok "cron install replaces the legacy vless-router-panel line"
else
	bad "legacy cron line not replaced ($(cat "$AU_CRON"))"
fi
IPKG_INSTROOT=/tmp au_cron_remove

# --- vless.sh update: fetch + store inactive proto (no switch) ---
cat > "$TMP/curl-stub.sh" <<'ST'
#!/bin/sh
# $1 url $2 outfile  (VLESS_AU_CURL protocol)
url=$1 out=$2
base=${VLESS_AU_FIXTURES:-}
f=$base/$(echo "$url" | sed 's#https://##' | tr '/' '_')
if [ -f "$f" ]; then cp "$f" "$out"; exit 0; fi
echo "stub curl: no fixture for $url" >&2
exit 1
ST
chmod 755 "$TMP/curl-stub.sh"
export VLESS_AU_CURL=$TMP/curl-stub.sh
export VLESS_AU_FIXTURES=$TMP/fx
mkdir -p "$TMP/fx"
printf 'hysteria2://newpass@192.0.2.80:443?sni=new.example\n' > "$TMP/fx/example.com_hy2"
# store_hy2 needs ucode; stub it
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ucode" <<'ST'
#!/bin/sh
# Test stub: write a dummy hysteria yaml, ignore gen.uc vs hy2.uc.
echo "server: stub"
echo "auth: stub"
exit 0
ST
chmod 755 "$TMP/bin/ucode"
# jq is real; nslookup/xray should not be called on inactive hy2 store (store_hy2 uses ucode only)
export PATH="$TMP/bin:$PATH"

au_save_conf hy2 1 24h
au_src_set hy2 'https://example.com/hy2'
# proto is vless, so update hy2 should only store
set +e
msg=$("$SH" update hy2 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$msg" | grep -q 'Сохранено' \
   && grep -q 'hysteria2://newpass@192.0.2.80:443' "$D/hy2.txt" \
   && [ "$(cat "$D/proto")" = vless ]; then
	ok "update inactive hy2 stores without switching proto"
else
	bad "update inactive hy2 (rc=$rc msg=$msg proto=$(cat "$D/proto") file=$(cat "$D/hy2.txt"))"
fi

# unchanged second run
set +e
msg=$("$SH" update hy2 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$msg" | grep -q 'без изменений'; then
	ok "update unchanged reports без изменений"
else
	bad "update unchanged (rc=$rc msg=$msg)"
fi

# empty field and non-http saved link: nothing to update, no fetch, exit 0
au_save_conf naive 1 24h
au_src_clear naive
set +e
msg=$("$SH" update naive 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$msg" | grep -q 'нечего обновлять'; then
	ok "update with no URL and non-http link: nothing to update"
else
	bad "no url update (rc=$rc msg=$msg)"
fi

# --- active proto: apply hook writes new file, probe fails, rollback ---
printf 'vless://00000000-0000-0000-0000-000000000000@192.0.2.10:443?sni=example.com\n' > "$D/link.txt"
printf 'OLDCFG\n' > "$D/config.json"
echo vless > "$D/proto"
printf 'vless://99999999-9999-9999-9999-999999999999@192.0.2.90:443?sni=new.example\n' > "$TMP/fx/example.com_vless"
au_save_conf vless 1 24h
au_src_set vless 'https://example.com/vless'

cat > "$TMP/apply-stub.sh" <<'ST'
#!/bin/sh
# Simulate a successful apply that replaces link.txt and config.json
printf '%s\n' "$(cat "$2")" > "$VLESS_PANEL_DIR/link.txt"
echo NEWCFG > "$VLESS_PANEL_DIR/config.json"
echo vless > "$VLESS_PANEL_DIR/proto"
exit 0
ST
chmod 755 "$TMP/apply-stub.sh"
cat > "$TMP/probe-fail.sh" <<'ST'
#!/bin/sh
exit 1
ST
chmod 755 "$TMP/probe-fail.sh"
cat > "$TMP/xrestart-stub.sh" <<'ST'
#!/bin/sh
echo xrestart >> "$VLESS_PANEL_DIR/xrestart.log"
exit 0
ST
chmod 755 "$TMP/xrestart-stub.sh"
cat > "$TMP/tproxy-stub.sh" <<'ST'
#!/bin/sh
echo tproxy-"$1" >> "$VLESS_PANEL_DIR/tproxy.log"
exit 0
ST
chmod 755 "$TMP/tproxy-stub.sh"

export VLESS_AU_APPLY=$TMP/apply-stub.sh
export VLESS_AU_PROBE=$TMP/probe-fail.sh
export VLESS_AU_XRESTART=$TMP/xrestart-stub.sh
export VLESS_AU_TPROXY=$TMP/tproxy-stub.sh

set +e
msg=$("$SH" update vless 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$msg" | grep -q 'откатан' \
   && grep -q '00000000-0000-0000-0000-000000000000' "$D/link.txt" \
   && grep -q 'OLDCFG' "$D/config.json" \
   && grep -q xrestart "$D/xrestart.log"; then
	ok "failed probe rolls back files and restarts"
else
	bad "rollback (rc=$rc msg=$msg link=$(cat "$D/link.txt") cfg=$(cat "$D/config.json"))"
fi

# tproxy should be brought up (tproxy.disabled absent)
if grep -q tproxy-up "$D/tproxy.log"; then
	ok "tproxy kept up after rollback"
else
	bad "tproxy not called after rollback ($(cat "$D/tproxy.log" 2>/dev/null))"
fi

# --- active proto: apply + probe success, no leftover old content ---
: > "$D/xrestart.log"
: > "$D/tproxy.log"
cat > "$TMP/probe-ok.sh" <<'ST'
#!/bin/sh
exit 0
ST
chmod 755 "$TMP/probe-ok.sh"
export VLESS_AU_PROBE=$TMP/probe-ok.sh
# Reset to old, fixture still has the new vless
printf 'vless://00000000-0000-0000-0000-000000000000@192.0.2.10:443?sni=example.com\n' > "$D/link.txt"
printf 'OLDCFG\n' > "$D/config.json"

set +e
msg=$("$SH" update vless 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$msg" | grep -q 'OK' \
   && grep -q '99999999-9999-9999-9999-999999999999' "$D/link.txt" \
   && grep -q 'NEWCFG' "$D/config.json" \
   && grep -q tproxy-up "$D/tproxy.log"; then
	ok "successful apply keeps new files and tproxy up"
else
	bad "successful apply (rc=$rc msg=$msg link=$(cat "$D/link.txt") cfg=$(cat "$D/config.json"))"
fi

# --- vless.sh src: subscription URL in a card field ---
printf 'https://example.com/hy2\n' > "$TMP/field.in"
rm -f "$(au_src_file hy2)"
if "$SH" src hy2 "$TMP/field.in" "$TMP/field.out" 1 >/dev/null 2>&1 \
   && grep -q 'hysteria2://newpass@192.0.2.80:443' "$TMP/field.out" \
   && [ "$(au_resolve_url hy2)" = "https://example.com/hy2" ]; then
	ok "src: URL is fetched, link extracted, URL remembered as source"
else
	bad "src fetch"
fi
printf 'hysteria2://direct@192.0.2.81:443\n' > "$TMP/field.in"
if "$SH" src hy2 "$TMP/field.in" "$TMP/field.out" 1 >/dev/null 2>&1 \
   && grep -q 'direct@192.0.2.81' "$TMP/field.out" && [ -z "$(au_resolve_url hy2)" ]; then
	ok "src: a direct link is passed through and clears the source"
else
	bad "src direct"
fi
printf 'https://example.com/nothing-here\n' > "$TMP/field.in"
if "$SH" src hy2 "$TMP/field.in" "$TMP/field.out" 1 >/dev/null 2>&1; then
	bad "src should fail when the URL cannot be fetched"
else
	ok "src fails on an unfetchable URL and keeps no source"
fi
printf 'https://example.com/hy2\n' > "$TMP/field.in"
"$SH" src hy2 "$TMP/field.in" "$TMP/field.out" 0 >/dev/null 2>&1
if [ "$(au_resolve_url hy2)" = "https://example.com/hy2" ]; then
	ok "src with fetch=0 only records the source"
else
	bad "src fetch=0"
fi
au_src_clear hy2

# --- socks/http store, mergecfg, backup (no xray, no ucode) ---
if au_ok_proto socks || au_ok_proto http; then
	bad "au_ok_proto must not include socks/http (no autoupdate)"
else
	ok "au_ok_proto rejects socks/http"
fi
if "$SH" autoset socks 1 1h >/dev/null 2>&1; then
	bad "autoset socks should fail"
else
	ok "autoset socks rejected"
fi
# store: valid socks, mode 600, password not leaked by the OK line
cat > "$TMP/socks.in" <<'JSON'
{"address":"192.0.2.80","port":1080,"user":"alice","pass":"s3cret"}
JSON
chmod 644 "$TMP/socks.in"
if "$SH" store socks "$TMP/socks.in" >/tmp/store-socks.out 2>&1 \
   && [ "$(jq -r .address "$D/socks.json")" = 192.0.2.80 ] \
   && [ "$(jq -r .port "$D/socks.json")" = 1080 ] \
   && [ "$(stat -c %a "$D/socks.json")" = 600 ]; then
	ok "store socks writes 0600 JSON"
else
	bad "store socks"
fi
if grep -q s3cret /tmp/store-socks.out 2>/dev/null; then
	bad "store socks printed a password"
else
	ok "store socks does not print a password"
fi
# store: reject a bad port (do not dump the file on failure)
printf '{"address":"192.0.2.80","port":0}\n' > "$TMP/socks.bad"
if "$SH" store socks "$TMP/socks.bad" >/tmp/store-socks-bad.out 2>&1; then
	bad "store socks should reject port 0"
else
	ok "store socks rejects port 0"
fi
printf '{"address":"","port":1080}\n' > "$TMP/socks.bad"
if "$SH" store socks "$TMP/socks.bad" >/tmp/store-socks-bad.out 2>&1; then
	bad "store socks should reject an empty address"
else
	ok "store socks rejects an empty address"
fi
# store http with TLS
cat > "$TMP/http.in" <<'JSON'
{"address":"192.0.2.81","port":443,"user":"","pass":"","tls":true,"sni":"proxy.example","allowInsecure":true}
JSON
if "$SH" store http "$TMP/http.in" >/dev/null 2>&1 \
   && [ "$(jq -r .tls "$D/http.json")" = true ] \
   && [ "$(jq -r .sni "$D/http.json")" = proxy.example ] \
   && [ "$(jq -r .allowInsecure "$D/http.json")" = true ] \
   && [ "$(stat -c %a "$D/http.json")" = 600 ]; then
	ok "store http writes TLS settings as 0600 JSON"
else
	bad "store http"
fi

# mergecfg: fixture inbounds/routing, no real credentials in the result checks
cat > "$TMP/base.json" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"tag": "tproxy", "port": 12345},
    {"tag": "redir", "port": 12346},
    {"tag": "dns-in", "port": 5354},
    {"tag": "socks", "port": 10808},
    {"tag": "http", "port": 10809}
  ],
  "outbounds": [
    {"tag": "proxy", "protocol": "freedom"},
    {"tag": "direct", "protocol": "freedom", "streamSettings": {"sockopt": {"mark": 255}}}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "inboundTag": ["dns-in"], "outboundTag": "proxy"},
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"},
      {"type": "field", "network": "tcp,udp", "outboundTag": "proxy"}
    ]
  }
}
JSON
if "$SH" mergecfg socks "$TMP/base.json" "$D/socks.json" "$TMP/out.socks.json" >/dev/null 2>&1 \
   && [ "$(jq -r '.outbounds[] | select(.tag=="proxy") | .protocol' "$TMP/out.socks.json")" = socks ] \
   && [ "$(jq -r '.outbounds[] | select(.tag=="proxy") | .settings.servers[0].address' "$TMP/out.socks.json")" = 192.0.2.80 ] \
   && [ "$(jq -r '.outbounds[] | select(.tag=="proxy") | .settings.servers[0].port' "$TMP/out.socks.json")" = 1080 ] \
   && [ "$(jq -r '.outbounds[] | select(.tag=="proxy") | .settings.servers[0].users[0].user' "$TMP/out.socks.json")" = alice ] \
   && [ "$(jq -r '.outbounds[] | select(.tag=="proxy") | .streamSettings.sockopt.mark' "$TMP/out.socks.json")" = 255 ] \
   && [ "$(jq -r '.inbounds[] | select(.tag=="socks") | .port' "$TMP/out.socks.json")" = 10808 ]; then
	ok "mergecfg socks builds a marked socks outbound and keeps inbounds"
else
	bad "mergecfg socks"
fi
# socks without auth: no users array
jq '{address,port,user:"",pass:""}' "$D/socks.json" > "$TMP/socks.nouser.json"
if "$SH" mergecfg socks "$TMP/base.json" "$TMP/socks.nouser.json" "$TMP/out.socks2.json" >/dev/null 2>&1 \
   && [ "$(jq -r '.outbounds[] | select(.tag=="proxy") | .settings.servers[0] | has("users")' "$TMP/out.socks2.json")" = false ]; then
	ok "mergecfg socks omits users when login is empty"
else
	bad "mergecfg socks without auth"
fi
if "$SH" mergecfg http "$TMP/base.json" "$D/http.json" "$TMP/out.http.json" >/dev/null 2>&1 \
   && [ "$(jq -r '.outbounds[] | select(.tag=="proxy") | .protocol' "$TMP/out.http.json")" = http ] \
   && [ "$(jq -r '.outbounds[] | select(.tag=="proxy") | .streamSettings.security' "$TMP/out.http.json")" = tls ] \
   && [ "$(jq -r '.outbounds[] | select(.tag=="proxy") | .streamSettings.tlsSettings.serverName' "$TMP/out.http.json")" = proxy.example ] \
   && [ "$(jq -r '.outbounds[] | select(.tag=="proxy") | .streamSettings.tlsSettings.allowInsecure' "$TMP/out.http.json")" = true ] \
   && [ "$(jq -r '.outbounds[] | select(.tag=="proxy") | .streamSettings.sockopt.mark' "$TMP/out.http.json")" = 255 ] \
   && [ "$(jq -r '[.routing.rules[] | select(.outboundTag=="dns-out" and .inboundTag==["dns-in"])] | length' "$TMP/out.http.json")" -ge 1 ] \
   && [ "$(jq -r '[.routing.rules[] | select(.network=="udp" and .port=="443" and .outboundTag=="block")] | length' "$TMP/out.http.json")" -ge 1 ] \
   && [ "$(jq -r '[.routing.rules[] | select(.network=="udp" and .outboundTag=="direct" and (.port|not))] | length' "$TMP/out.http.json")" -ge 1 ]; then
	ok "mergecfg http uses TLS and sends UDP direct / blocks QUIC"
else
	bad "mergecfg http"
fi
# default SNI is the address when tls is on and sni is empty
jq '.sni=""' "$D/http.json" > "$TMP/http.nosni.json"
if "$SH" mergecfg http "$TMP/base.json" "$TMP/http.nosni.json" "$TMP/out.http2.json" >/dev/null 2>&1 \
   && [ "$(jq -r '.outbounds[] | select(.tag=="proxy") | .streamSettings.tlsSettings.serverName' "$TMP/out.http2.json")" = 192.0.2.81 ]; then
	ok "mergecfg http defaults SNI to the address"
else
	bad "mergecfg http default SNI"
fi

# backup / restore keeps socks.json and http.json
B=$TMP/bak-proxy
au_backup "$B"
jq '.address="0.0.0.0"' "$D/socks.json" > "$D/socks.json.tmp" && mv "$D/socks.json.tmp" "$D/socks.json"
rm -f "$D/http.json"
au_restore "$B"
if [ "$(jq -r .address "$D/socks.json")" = 192.0.2.80 ] \
   && [ "$(jq -r .sni "$D/http.json")" = proxy.example ]; then
	ok "au_backup/restore keeps socks.json and http.json"
else
	bad "au_backup/restore proxy settings"
fi

# --- sh -n of scripts ---
for s in \
	"$SH" \
	"$ROOT/files/www-aurora/cgi-bin/vless" \
	"$ROOT/files/usr/libexec/aurora-panel/autoupdate-run.sh" \
	"$ROOT/files/usr/libexec/aurora-panel/install-naive.sh" \
	"$ROOT/control/postinst" "$ROOT/control/prerm" "$ROOT/control/postrm"
do
	if sh -n "$s"; then
		ok "sh -n $(basename "$s")"
	else
		bad "sh -n $(basename "$s")"
	fi
done

if [ "$fail" -ne 0 ]; then
	echo "FAILED: $fail test(s)"
	exit 1
fi
echo "All autoupdate tests passed."
exit 0
