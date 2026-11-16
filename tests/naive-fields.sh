#!/bin/sh
# Naive card: official NaiveProxy config.json from separate fields; the saved password
# never reaches the page; status card shows the configured host and the server port.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SH=$ROOT/files/etc/panel/vpn.sh
CGI=$ROOT/files/www-vpn-panel/cgi-bin/vpn
LIB=$ROOT/files/usr/libexec/vpn-panel/autoupdate-lib.sh
fail=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
D=$TMP/etc/xray; NAD=$TMP/etc/naive
mkdir -p "$D/autoupdate" "$NAD" "$TMP/bin"
export VLESS_PANEL_DIR=$D VLESS_NAIVE_DIR=$NAD VLESS_AU_LIB=$LIB VLESS_SH=$SH
# no DNS in tests: a fixed answer for any name
cat > "$TMP/bin/nslookup" <<'X'
#!/bin/sh
printf 'Server: 127.0.0.1\nAddress: 127.0.0.1#53\n\nName: %s\nAddress: 198.51.100.8\n' "$1"
X
chmod 755 "$TMP/bin/nslookup"; PATH=$TMP/bin:$PATH; export PATH
PW='s3cr3t-Pw'

# --- 1. a link saved by an older version: the same config.json as before ---
printf 'naive+https://user:%s@nv.example:8445#Home\n' "$PW" > "$TMP/link"
"$SH" store naive "$TMP/link" >/dev/null
old=$(jq -n --arg p "https://user:$PW@nv.example:8445" --arg r "MAP nv.example 198.51.100.8" '{listen:["socks://127.0.0.1:10828","redir://0.0.0.0:12366"],proxy:$p,"host-resolver-rules":$r}')
if [ "$(cat "$NAD/config.json")" = "$old" ]; then ok "a naive+https:// link gives byte-for-byte the config.json of the old link field"; else bad "link config: $(cat "$NAD/config.json")"; fi
cp "$NAD/config.json" "$TMP/cfg1"

# --- 2. the same values typed into the fields: identical file ---
printf 'host=nv.example\nport=8445\nuser=user\npass=%s\nscheme=https\nconcurrency=\ntunnel_timeout=\nidle_timeout=\n' "$PW" > "$TMP/f"
"$SH" store naive "$TMP/f" >/dev/null
if cmp -s "$TMP/cfg1" "$NAD/config.json"; then ok "the same values from the fields give an identical config.json"; else bad "fields config differs"; fi
# empty password keeps the saved one
printf 'host=nv.example\nport=8445\nuser=user\npass=\nscheme=https\n' > "$TMP/f"
"$SH" store naive "$TMP/f" >/dev/null
if cmp -s "$TMP/cfg1" "$NAD/config.json"; then ok "an empty password field keeps the saved password"; else bad "blank password: $(jq -r .proxy "$NAD/config.json" | sed 's#//.*@#//***@#')"; fi

# --- 3. special characters are percent-encoded; optional upstream keys ---
printf 'host=203.0.113.5\nport=\nuser=a b@c\npass=p:w,/%%x\nscheme=quic\nconcurrency=2\ntunnel_timeout=900\nidle_timeout=300\nheader=X-A: 1\nheader=X-B: two words\n' > "$TMP/f"
"$SH" store naive "$TMP/f" >/dev/null
if [ "$(jq -r .proxy "$NAD/config.json")" = 'quic://a%20b%40c:p%3Aw%2C%2F%25x@203.0.113.5:443' ] \
   && [ "$(jq -r '."host-resolver-rules"' "$NAD/config.json")" = 'MAP 203.0.113.5 203.0.113.5' ] \
   && [ "$(jq -c '[."insecure-concurrency",."tunnel-timeout",."idle-timeout"]' "$NAD/config.json")" = '[2,900,300]' ] \
   && [ "$(jq -r '."extra-headers"' "$NAD/config.json" | od -c | grep -c '\\r')" = 1 ] \
   && [ "$(jq -c .listen "$NAD/config.json")" = '["socks://127.0.0.1:10828","redir://0.0.0.0:12366"]' ] \
   && [ "$(stat -c %a "$NAD/config.json")" = 600 ]; then
	ok "user/password percent-encoded, quic scheme, default port 443, optional keys, listen kept, file 0600"
else bad "encoded config: $(cat "$NAD/config.json")"; fi
s=$("$SH" naive-show); echo() { printf "%s\n" "$*"; }
if [ "$(echo "$s" | jq -r .user)" = 'a b@c' ] && [ "$(echo "$s" | jq -r .has_pass)" = true ] && ! echo "$s" | grep -q 'p:w' && ! echo "$s" | grep -q 'p%3A' \
   && [ "$(echo "$s" | jq -r .headers)" = "$(printf 'X-A: 1\nX-B: two words')" ] && [ "$(echo "$s" | jq -r .scheme)" = quic ]; then
	ok "naive-show decodes the fields and never prints the password"
else bad "naive-show: $s"; fi
# a subscription link keeps the optional keys
printf 'naive+https://u2:p2@nv2.example:443\n' > "$TMP/link"; "$SH" store naive "$TMP/link" >/dev/null
if [ "$(jq -r '."insecure-concurrency"' "$NAD/config.json")" = 2 ] && [ "$(jq -r .proxy "$NAD/config.json")" = 'https://u2:p2@nv2.example:443' ]; then ok "a link (subscription) changes the server and keeps the optional keys"; else bad "link merge"; fi

# --- 4. validation ---
chk(){ printf "$1" > "$TMP/f"; out=$("$SH" store naive "$TMP/f" 2>&1 || true); printf '%s' "$out" | grep -q "$2"; }
cp "$NAD/config.json" "$TMP/before"
if chk 'host=bad_host\nuser=u\npass=p\n' 'host name' && chk 'host=h.example\nport=0\nuser=u\npass=p\n' '1 to 65535' \
   && chk 'host=h.example\nport=70000\nuser=u\npass=p\n' '1 to 65535' && chk 'host=h.example\nport=8a\nuser=u\npass=p\n' '1 to 65535' \
   && chk 'host=h.example\nscheme=socks\nuser=u\npass=p\n' 'https or quic' && chk 'host=h.example\nuser=u\npass=p\nconcurrency=99\n' 'Concurrency' \
   && chk 'host=h.example\nuser=u\npass=p\nheader=no colon\n' 'Name: value' && chk 'host=\nuser=u\npass=p\n' 'Enter the Naive server' \
   && chk 'host=h"x.example\nuser=u\npass=p\n' 'host name' && cmp -s "$TMP/before" "$NAD/config.json"; then
	ok "bad host, port, scheme, concurrency and headers are refused and config.json is left untouched"
else bad "validation ($out)"; fi

# --- 5. page: fields from the saved settings, password never in the HTML ---
rm -f "$NAD/config.json"
printf 'naive+https://user:%s@nv.example:8445#Home\n' "$PW" > "$D/naive.txt"
echo naive > "$D/proto"
page=$(env REQUEST_METHOD=GET "$CGI" 2>/dev/null)
if printf '%s' "$page" | grep -q 'name=host value="nv.example"' && printf '%s' "$page" | grep -q 'name=port value="8445"' \
   && printf '%s' "$page" | grep -q 'name=user value="user"' && printf '%s' "$page" | grep -q 'type=password name=pass value=""' \
   && printf '%s' "$page" | grep -q 'saved, leave empty to keep' && ! printf '%s' "$page" | grep -q "$PW" \
   && ! printf '%s' "$page" | grep -q 'naive+https://user' && printf '%s' "$page" | grep -q 'class=pwt' \
   && printf '%s' "$page" | grep -q 'class=advbox' && printf '%s' "$page" | grep -q 'name=scheme' \
   && ! printf '%s' "$page" | grep -q '<details'; then
	ok "an old saved link fills Server/Port/Username, the password stays masked and out of the page"
else bad "naive page fields"; fi
row() { printf '%s\n' "$page" | sed -n "s/.*<tr><td>$1<\\/td><td>\\(.*\\)<\\/td><\\/tr>.*/\\1/p" | head -1; }
if [ "$(row 'Server:')" = nv.example ] && printf '%s' "$page" | grep -q 'id=egress data-port="8445"'; then ok "status: Server is the configured host, the egress cell carries the Naive port"; else bad "naive status row: $(row 'Server:')"; fi

# --- 6. CGI POST: fields go to vpn.sh in a file, password not on a command line ---
cat > "$TMP/vsh" <<X
#!/bin/sh
echo "\$*" >> "$TMP/vsh.args"
case "\$1" in naivesave) cp "\$2" "$TMP/posted";; naive-show) exec "$SH" naive-show;; status) printf 'proto=naive\n';; esac
echo OK
X
chmod 755 "$TMP/vsh"
body="action=naivesave&proto=naive&host=nv.example&port=8445&user=us%2Ber&pass=p%40ss+w&scheme=quic&conc=2&tt=&it=&hdr=X-A%3A+1%0D%0AX-B%3A+2&sub="
env VLESS_SH="$TMP/vsh" REQUEST_METHOD=POST CONTENT_LENGTH=${#body} "$CGI" >/dev/null 2>&1 <<B
$body
B
if grep -qx 'host=nv.example' "$TMP/posted" && grep -qx 'user=us+er' "$TMP/posted" && grep -qx 'pass=p@ss w' "$TMP/posted" \
   && grep -qx 'scheme=quic' "$TMP/posted" && grep -qx 'concurrency=2' "$TMP/posted" && grep -qx 'header=X-A: 1' "$TMP/posted" && grep -qx 'header=X-B: 2' "$TMP/posted" \
   && ! grep -q 'p@ss' "$TMP/vsh.args" && grep -q '^src naive' "$TMP/vsh.args"; then
	ok "Connect Naive posts the decoded fields as a file; the password never appears in arguments"
else bad "naive POST ($(cat "$TMP/vsh.args"))"; fi

# --- 7. status: host only and port for every protocol ---
printf 'vless://00000000-0000-0000-0000-000000000000@vl.example:8443?sni=x.example\n' > "$D/link.txt"
printf 'hysteria2://pw@198.51.100.20:4443/?sni=hy.example\n' > "$D/hy2.txt"
echo '{"settings":{"peers":[{"endpoint":"wg.example:51820"}]}}' > "$D/wg.json"
echo '{"address":"px.example","port":1080}' > "$D/socks.json"
r=
for p in vless hy2 wg socks; do
	echo $p > "$D/proto"; page=$(env REQUEST_METHOD=GET "$CGI" 2>/dev/null)
	r="$r $(row 'Server:')/$(printf '%s' "$page" | sed -n 's/.*id=egress data-port="\([^"]*\)".*/\1/p')"
done
if [ "$r" = ' vl.example/8443 198.51.100.20/4443 wg.example/51820 px.example/1080' ]; then ok "status: Server/port come from each protocol's own saved config (host name, or the IP when set by IP)"; else bad "status rows:$r"; fi

if [ "$fail" -eq 0 ]; then echo "All Naive field tests passed."; else echo "$fail Naive field test(s) failed." >&2; exit 1; fi
