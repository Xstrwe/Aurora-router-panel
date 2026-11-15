#!/bin/sh
# Tests for aurora-geoip.sh (geoip.dat parser) and aurora-split.sh (per-protocol nft split).
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GEO=$ROOT/files/usr/libexec/aurora-panel/aurora-geoip.sh
SPLIT=$ROOT/files/usr/libexec/aurora-panel/aurora-split.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=$((fail+1)); }

# --- a tiny geoip.dat: RU (two IPv4 ranges, one IPv6) and US ---
python3 - "$TMP/geoip.dat" <<'PY'
import sys
def varint(n):
    o=b''
    while True:
        b=n&0x7f; n>>=7
        if n: o+=bytes([b|0x80])
        else: o+=bytes([b]); return o
def cidr(ip,pre):
    body=b'\x0a'+varint(len(ip))+ip+b'\x10'+varint(pre)
    return b'\x12'+varint(len(body))+body
def geo(cc,cidrs):
    body=b'\x0a'+varint(len(cc))+cc.encode()+b''.join(cidrs)
    return b'\x0a'+varint(len(body))+body
dat=geo('US',[cidr(bytes([8,8,8,0]),24)])
dat+=geo('RU',[cidr(bytes([5,8,0,0]),16),cidr(bytes([77,88,0,0]),18),cidr(bytes(16),32)]+[cidr(bytes([95,x,0,0]),16) for x in range(200)])
open(sys.argv[1],'wb').write(dat)
PY
out=$(AURORA_GEOIP_DAT="$TMP/geoip.dat" AURORA_GEO_CACHE="$TMP/geo" sh "$GEO" ru)
if [ "$(printf '%s\n' "$out" | sed -n 1,2p | tr '\n' ' ')" = "5.8.0.0/16 77.88.0.0/18 " ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 202 ] \
   && ! printf '%s\n' "$out" | grep -q ':'; then
	ok "geoip.dat parser returns the IPv4 ranges of one country (IPv6 skipped)"
else
	bad "geoip parse ($(printf '%s\n' "$out" | head -3 | tr '\n' ' '))"
fi
us=$(AURORA_GEOIP_DAT="$TMP/geoip.dat" AURORA_GEO_CACHE="$TMP/geo" sh "$GEO" US)
[ "$us" = 8.8.8.0/24 ] && ok "another country is found by its code" || bad "geoip US ($us)"
if AURORA_GEOIP_DAT="$TMP/geoip.dat" AURORA_GEO_CACHE="$TMP/geo" sh "$GEO" ZZ >/dev/null 2>&1; then bad "unknown country must fail"; else ok "an unknown country code fails cleanly"; fi

# --- split rules: one table, one config file, one server address per protocol ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/nft" <<NFT
#!/bin/sh
echo "nft \$*" >> "$TMP/calls.log"
[ "\$1" = -f ] && cp "\$2" "$TMP/loaded.nft"
exit 0
NFT
cat > "$TMP/bin/ip" <<IPS
#!/bin/sh
echo "ip \$*" >> "$TMP/calls.log"
exit 0
IPS
chmod 755 "$TMP/bin/nft" "$TMP/bin/ip"
export AURORA_NFT="$TMP/bin/nft" AURORA_IP="$TMP/bin/ip" AURORA_GEOIP_DAT="$TMP/geoip.dat" AURORA_GEO_CACHE="$TMP/geo" AURORA_DNSPROXY_UP=1
export AURORA_HY_SPLIT="$TMP/hy.split" AURORA_HY_SERVER_IP="$TMP/hy.ip" AURORA_NV_SPLIT="$TMP/nv.split" AURORA_NV_SERVER_IP="$TMP/nv.ip" AURORA_WG_SPLIT="$TMP/wg.split" AURORA_WG_SERVER_IP="$TMP/wg.ip"
echo 192.0.2.7 > "$TMP/hy.ip"; echo 192.0.2.8 > "$TMP/nv.ip"; echo 192.0.2.9 > "$TMP/wg.ip"
for p in hy nv wg; do sh "$SPLIT" $p render > "$TMP/$p.render" 2>"$TMP/$p.err" || bad "render $p failed ($(cat "$TMP/$p.err"))"; done
if grep -q '^table inet aurora_hy {' "$TMP/hy.render" && grep -q '^table inet aurora_nv {' "$TMP/nv.render" && grep -q '^table inet aurora_wg {' "$TMP/wg.render" \
   && ! grep -q 'aurora_nv\|aurora_wg' "$TMP/hy.render" && ! grep -q 'aurora_hy\|aurora_wg' "$TMP/nv.render" && ! grep -q 'aurora_hy\|aurora_nv' "$TMP/wg.render"; then
	ok "each protocol renders its own nft table, with no reference to another one"
else
	bad "table separation"
fi
if grep -q '192.0.2.7' "$TMP/hy.render" && ! grep -q '192.0.2.8\|192.0.2.9' "$TMP/hy.render" \
   && grep -q '192.0.2.8' "$TMP/nv.render" && ! grep -q '192.0.2.7\|192.0.2.9' "$TMP/nv.render" \
   && grep -q '192.0.2.9' "$TMP/wg.render" && ! grep -q '192.0.2.7\|192.0.2.8' "$TMP/wg.render"; then
	ok "each table bypasses only its own server address"
else
	bad "server address bypass"
fi
if grep -q '5.8.0.0/16' "$TMP/hy.render" && grep -q '77.88.0.0/18' "$TMP/hy.render" && grep -q '10.0.0.0/8' "$TMP/hy.render" && [ -s "$TMP/hy.split" ] && [ -s "$TMP/nv.split" ] && [ -s "$TMP/wg.split" ]; then
	ok "default config: private and RU ranges go direct; each protocol got its own editable split file"
else
	bad "default split"
fi
grep -q 'redirect to :12356' "$TMP/hy.render" && grep -q 'tproxy ip to 127.0.0.1:12355' "$TMP/hy.render" && grep -q 'th dport 53 counter redirect to :5364' "$TMP/hy.render" \
 && ok "Hysteria: TCP redirect and UDP TProxy to its own listeners, DNS to its own forwarder" || bad "hy rules"
grep -q 'redirect to :12366' "$TMP/nv.render" && grep -q 'udp dport 443 counter drop' "$TMP/nv.render" && grep -q 'meta skuid 65534 ip daddr 1.1.1.1 tcp dport 53 counter redirect to :12366' "$TMP/nv.render" \
 && ok "Naive: TCP redirect to its own listener, QUIC dropped, DNS helper's TCP query goes through Naive" || bad "nv rules"
grep -q '0x5a000000' "$TMP/wg.render" && grep -q 'oifname "wg-aurora" counter masquerade' "$TMP/wg.render" && ! grep -q 'redirect\|tproxy' "$TMP/wg.render" \
 && ok "WireGuard: fwmark policy routing, masquerade, no proxy redirect" || bad "wg rules"
# mode all: geoip ranges are ignored, explicit CIDRs and private ranges stay direct; a user line is honoured.
printf 'mode all\ndirect private\ndirect geoip:ru\ndirect 203.0.113.0/24\n' > "$TMP/hy.split"
sh "$SPLIT" hy render > "$TMP/hy2.render"
if ! grep -q '5.8.0.0/16' "$TMP/hy2.render" && grep -q '203.0.113.0/24' "$TMP/hy2.render" && grep -q '192.168.0.0/16' "$TMP/hy2.render" && ! grep -q 'mode all' "$TMP/hy2.render"; then
	ok "mode all drops the country ranges; private ranges and own CIDR lines stay direct"
else
	bad "mode all render"
fi
# Naive without a running DNS helper must not redirect DNS.
AURORA_DNSPROXY_UP= sh -c "PATH=/nonexistent:/usr/bin:/bin; unset AURORA_DNSPROXY_UP; sh '$SPLIT' nv render" > "$TMP/nv2.render" 2>/dev/null
if ! grep -q 'redirect to :5374' "$TMP/nv2.render"; then ok "Naive: DNS is only redirected while its DNS helper runs"; else bad "nv dns guard"; fi
# up / down touch only that protocol's table and rules.
rm -f "$TMP/calls.log"
sh "$SPLIT" hy up && sh "$SPLIT" hy down
if grep -q 'delete table inet aurora_hy' "$TMP/calls.log" && grep -q 'rule add fwmark 0x11 lookup 111' "$TMP/calls.log" \
   && ! grep -q 'aurora_nv\|aurora_wg\|xray\|871\|table 100' "$TMP/calls.log" && [ -s "$TMP/loaded.nft" ]; then
	ok "Hysteria up/down changes only its own table and routing rule"
else
	bad "hy up/down ($(tr '\n' ';' < "$TMP/calls.log"))"
fi
rm -f "$TMP/calls.log"
sh "$SPLIT" wg up && sh "$SPLIT" wg down
if grep -q 'rule add fwmark 0x5a000000/0xff000000 lookup 871' "$TMP/calls.log" && grep -q 'delete table inet aurora_wg' "$TMP/calls.log" \
   && ! grep -q 'aurora_hy\|aurora_nv\|xray' "$TMP/calls.log"; then
	ok "WireGuard up/down changes only its own table and policy rule"
else
	bad "wg up/down ($(tr '\n' ';' < "$TMP/calls.log"))"
fi
if sh "$SPLIT" bogus up >/dev/null 2>&1; then bad "unknown protocol accepted"; else ok "unknown protocol is refused"; fi
# The helper never touches Xray's files or table.
if ! grep -q '/etc/xray/config\|inet xray\|xray-client' "$SPLIT" "$GEO"; then ok "the split helper has no reference to Xray's config, table or service"; else bad "xray reference in helper"; fi


# --- client binary updates: one client from its own upstream, only its own service restarted ---
CU=$ROOT/files/usr/libexec/aurora-panel/client-update.sh
mkdir -p "$TMP/srv" "$TMP/cb" "$TMP/up"
ARCHN=$(uname -m); case "$ARCHN" in aarch64) XA=arm64-v8a; HA=arm64;; x86_64) XA=64; HA=amd64;; *) XA=""; HA="";; esac
if [ -n "$XA" ] && command -v unzip >/dev/null 2>&1; then
	printf '#!/bin/sh\n[ "$1" = version ] && echo "Xray 9.9.9 (Xray, Penetrates Everything.)"\nexit 0\n' > "$TMP/up/xray"
	( cd "$TMP/up" && python3 -c "import zipfile;zipfile.ZipFile('$TMP/srv/Xray-linux-$XA.zip','w').write('xray')" )
	printf 'SHA2-256= %s\n' "$(sha256sum "$TMP/srv/Xray-linux-$XA.zip" | cut -d' ' -f1)" > "$TMP/srv/Xray-linux-$XA.zip.dgst"
	printf '#!/bin/sh\n[ "$1" = version ] && printf "Version:\\tv9.9.9\\n"\nexit 0\n' > "$TMP/srv/hysteria-linux-$HA"
	printf '%s  build/hysteria-linux-%s\n' "$(sha256sum "$TMP/srv/hysteria-linux-$HA" | cut -d' ' -f1)" "$HA" > "$TMP/srv/hashes.txt"
	cat > "$TMP/cb/curl" <<CURL
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift;; http*) url=\$1;; esac; shift; done
case "\$url" in
  */repos/XTLS/Xray-core/releases/latest) echo '{"tag_name":"v9.9.9"}';;
  */repos/apernet/hysteria/releases/latest) echo '{"tag_name":"app/v9.9.9"}';;
  *) f=$TMP/srv/\$(basename "\$url"); [ -f "\$f" ] || exit 22; cp "\$f" "\$out";;
esac
CURL
	printf '#!/bin/sh\necho "$@" >> "%s/vsh.log"\nexit 0\n' "$TMP" > "$TMP/cb/vless.sh"
	printf '#!/bin/sh\n[ "$1" = "$PIDOF_ONLY" ] && echo 1 && exit 0\nexit 1\n' > "$TMP/cb/pidof"
	chmod 755 "$TMP/cb/"* "$TMP/srv/hysteria-linux-$HA"
	printf '#!/bin/sh\necho old\n' > "$TMP/cb/xray-old"; chmod 755 "$TMP/cb/xray-old"; cp "$TMP/cb/xray-old" "$TMP/xray.bin"; cp "$TMP/cb/xray-old" "$TMP/hy.bin"
	cuenv() { env PATH="$TMP/cb:$PATH" AURORA_GH_API=https://api.github.test AURORA_GH_DL=https://dl.github.test VLESS_AU_VLESS_SH="$TMP/cb/vless.sh" VLESS_XRAY_BIN="$TMP/xray.bin" VLESS_HYSTERIA_BIN="$TMP/hy.bin" "$@"; }
	chk=$(cuenv sh "$CU" hysteria check)
	case "$chk" in *"latest=9.9.9"*"source=apernet/hysteria"*) ok "client-update check reports the installed and upstream version and the source";; *) bad "check output ($chk)";; esac
	rm -f "$TMP/vsh.log"
	o=$(cuenv env PIDOF_ONLY=hysteria sh "$CU" hysteria install 2>&1)
	if printf '%s' "$o" | grep -q '^OK' && [ "$("$TMP/hy.bin" version)" = "$(printf 'Version:\tv9.9.9')" ] && [ "$(cat "$TMP/vsh.log")" = "restart-svc hysteria" ] && [ -e "$TMP/hy.bin.bak" ] \
	   && [ "$(cat "$TMP/xray.bin")" = "$(cat "$TMP/cb/xray-old")" ]; then
		ok "updating Hysteria replaces only its binary and restarts only the hysteria service; Xray's binary is untouched"
	else bad "hysteria update ($o | $(cat "$TMP/vsh.log" 2>/dev/null))"; fi
	rm -f "$TMP/vsh.log"
	o=$(cuenv env PIDOF_ONLY=none sh "$CU" xray install 2>&1)
	if printf '%s' "$o" | grep -q '^OK' && [ "$("$TMP/xray.bin" version | cut -c1-10)" = "Xray 9.9.9" ] && [ ! -e "$TMP/vsh.log" ]; then
		ok "updating Xray (stopped) replaces only its binary after a SHA-256 check and starts nothing"
	else bad "xray update ($o)"; fi
	echo 'tampered' > "$TMP/srv/hashes.txt"; rm -f "$TMP/hy.bin.bak"
	o=$(cuenv env PIDOF_ONLY=none sh "$CU" hysteria install 2>&1 || true)
	if printf '%s' "$o" | grep -q 'checksum mismatch'; then ok "a download that does not match the published checksum is refused"; else bad "checksum refusal ($o)"; fi
else
	echo "skip - client-update tests need unzip and x86_64/aarch64"
fi

[ "$fail" = 0 ] && echo "All split tests passed." || { echo "$fail split test(s) failed."; exit 1; }
