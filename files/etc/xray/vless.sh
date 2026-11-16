#!/bin/sh
# vless.sh save <linkfile> | hy2save <linkfile> | naivesave <linkfile> | wgsave <conffile>
#         | sockssave <json> | httpsave <json>
#         | store vless|hy2|naive|wg|socks|http <file> | proto vless|hy2|naive|wg|socks|http
#         | mode ru|all | on | off | status | restart | restart-svc xray|naive|hysteria|wireguard | recover | egress
#         | health | probe 204|youtube|ip|speed
#         | install xray|hy2|naive|wg | install-status [xray|hy2|naive|wg]
#         | autoset <proto> <0|1> <1h|6h|24h>
#         | src <proto> <infile> <outfile> <0|1> | update <proto>
#         | mergecfg socks|http <base.json> <settings.json> <out.json>
D=${VLESS_PANEL_DIR:-/etc/xray}
HYD=${VLESS_HYSTERIA_DIR:-/etc/hysteria}
NAD=${VLESS_NAIVE_DIR:-/etc/naive}
XRAY_BIN=${VLESS_XRAY_BIN:-/usr/bin/xray}
HYSTERIA_BIN=${VLESS_HYSTERIA_BIN:-/usr/bin/hysteria}
NAIVE_BIN=${VLESS_NAIVE_BIN:-/usr/bin/naive}
WG_BIN=${VLESS_WG_BIN:-/usr/bin/wg}
WGIF=wg-aurora
AURORA_SPLIT=${VLESS_AURORA_SPLIT:-/usr/libexec/vpn-panel/aurora-split.sh}
# per-protocol split configs and server addresses (read by aurora-split.sh)
export AURORA_HY_SPLIT=$HYD/split.conf AURORA_HY_SERVER_IP=$HYD/server_ip
export AURORA_NV_SPLIT=$NAD/split.conf AURORA_NV_SERVER_IP=$NAD/server_ip
export AURORA_WG_SPLIT=$D/wg.split.conf AURORA_WG_SERVER_IP=$D/wg.server_ip
AU_LIB=${VLESS_AU_LIB:-/usr/libexec/vpn-panel/autoupdate-lib.sh}
INITD=${VLESS_INITD:-/etc/init.d}
STABLE_SECS=${VLESS_AU_STABLE_SECS:-3}
EGRESS_CACHE=${VLESS_AU_EGRESS_CACHE:-/tmp/aurora-egress.cache}
# Xray start attempts: seconds to wait for one attempt, pause between attempts,
# and the total budget (uhttpd gives a script 90 s).
XSTART_WAIT=${VLESS_AU_XSTART_WAIT:-8}
XRETRY_PAUSE=${VLESS_AU_XRETRY_PAUSE:-3}
XRESTART_MAX=${VLESS_AU_XRESTART_MAX:-75}
RECOVER_LOCK=${VLESS_AU_RECOVER_LOCK:-/tmp/aurora-recover.lock}
err(){ echo "ERROR: $*"; exit 1; }
PROTO=$(cat $D/proto 2>/dev/null || echo vless)
# shellcheck disable=SC1090
[ -f "$AU_LIB" ] && . "$AU_LIB"
svc(){ [ -x "$INITD/$1" ] || return 0; if [ "$2" = 1 ]; then "$INITD/$1" enable >/dev/null 2>&1; "$INITD/$1" restart >/dev/null 2>&1; else "$INITD/$1" stop >/dev/null 2>&1; "$INITD/$1" disable >/dev/null 2>&1; fi; }
# WireGuard is a kernel interface (init script wireguard-client), not an Xray outbound.
wg_inst(){ # wireguard-tools and the kernel module are present
  [ -x "$WG_BIN" ] || return 1
  [ -d "${VLESS_WG_SYSMOD:-/sys/module/wireguard}" ] || ls "${VLESS_WG_KO:-/lib/modules/$(uname -r)}"/wireguard.ko >/dev/null 2>&1
}
wg_up(){ ip link show "$WGIF" >/dev/null 2>&1; }
xports_busy(){ # 0 if any of tcp 10808/12346 or udp 12345 is still bound
  [ -n "${VLESS_AU_PORTS_BUSY:-}" ] && return 0
  netstat -lnt 2>/dev/null | grep -qE ':(10808|12346) ' && return 0
  netstat -lnu 2>/dev/null | grep -qE ':12345 ' && return 0
  return 1
}
xports_up(){ # 0 when both tcp 10808 and 12346 listen
  _n=$(netstat -lnt 2>/dev/null)
  echo "$_n" | grep -q ':10808 ' && echo "$_n" | grep -q ':12346 '
}
xstop(){
  $INITD/xray-client stop >>/tmp/xray-restart.err 2>&1
  # wait up to 10s for xray to exit, then kill it
  i=0; while [ $i -lt 10 ] && pidof xray >/dev/null; do sleep 1; i=$((i+1)); done
  pidof xray >/dev/null && { killall -9 xray >/dev/null 2>&1; sleep 1; }
  # wait until the listen ports are released (a second instance would fail to bind)
  i=0; while [ $i -lt 10 ] && xports_busy; do sleep 1; i=$((i+1)); done
}
# Stop and start Xray. Under load the new process can fail to bind 12346 for up
# to about a minute after the old one died (connections left over from it), so a
# start is retried with a clean stop in between until XRESTART_MAX seconds pass.
# Transparent mode is switched off while Xray is not listening (otherwise the LAN
# would be redirected to a closed port) and back on as soon as it is.
xrestart(){
  if [ -n "${VLESS_AU_XRESTART:-}" ]; then sh "$VLESS_AU_XRESTART"; return $?; fi
  : > /tmp/xray-restart.err
  t0=$(date +%s)
  while :; do
    xstop
    $INITD/xray-client start >>/tmp/xray-restart.err 2>&1
    i=0; down=0
    while [ $i -lt $XSTART_WAIT ]; do
      if pidof xray >/dev/null && xports_up; then au_tproxy; return 0; fi
      sleep 1; i=$((i+1))
      if [ $i -ge 3 ] && [ $down = 0 ]; then down=1; $D/tproxy.sh down >/dev/null 2>&1; fi
    done
    [ $(( $(date +%s) - t0 )) -ge "$XRESTART_MAX" ] && break
    sleep "$XRETRY_PAUSE"
  done
  # Leave the crash loop; the LAN stays direct until Xray is back (see recover).
  $INITD/xray-client stop >>/tmp/xray-restart.err 2>&1
  $D/tproxy.sh down >/dev/null 2>&1
  return 1
}
au_tproxy(){
  [ -f $D/tproxy.disabled ] && return 0
  # Xray only steers traffic while it is the active protocol (proto file, not the stale $PROTO)
  case "$(cat $D/proto 2>/dev/null)" in hy2|naive|wg) $D/tproxy.sh down >/dev/null 2>&1; return 0;; esac
  if [ -n "${VLESS_AU_TPROXY:-}" ]; then sh "$VLESS_AU_TPROXY" up; return $?; fi
  $D/tproxy.sh up
}
au_probe(){
  if [ -n "${VLESS_AU_PROBE:-}" ]; then sh "$VLESS_AU_PROBE"; return $?; fi
  nat_probe_once "$PROTO"
}
au_fetch(){
  case "$1" in http://*|https://*) ;; *) err "auto-update link must start with http:// or https://";; esac
  if [ -n "${VLESS_AU_CURL:-}" ]; then
    sh "$VLESS_AU_CURL" "$1" "$2" || err "could not download the update"
  else
    curl -fL --max-time 25 --max-filesize 1048576 -A 'vpn-panel-gl-inet-autoupdate/1.5.0a1' -o "$2" "$1" || err "could not download the update"
  fi
  [ -s "$2" ] || err "empty auto-update response"
  sz=$(wc -c < "$2" | tr -d ' ')
  [ "$sz" -le 1048576 ] || err "auto-update response is too large"
}
# ---------------------------------------------------------------------------
# Native protocols: Hysteria, Naive and WireGuard. Each is its own service with
# its own config files and its own steering rules (aurora-split.sh); Xray is not
# involved. The only code shared between protocols is the switcher below, which
# decides which protocol is active and stops the others.
# ---------------------------------------------------------------------------
is_native(){ case "$1" in hy2|naive|wg) return 0;; esac; return 1; }
nat_set(){ # sets NSVC (init script), NSP (split id), NCFG (config), NNAME
  case "$1" in
    hy2) NSVC=hysteria-client; NSP=hy; NCFG=$HYD/client.yaml; NSPLIT=$HYD/split.conf; NNAME=Hysteria;;
    naive) NSVC=naive-client; NSP=nv; NCFG=$NAD/config.json; NSPLIT=$NAD/split.conf; NNAME=Naive;;
    wg) NSVC=wireguard-client; NSP=wg; NCFG=$D/wg.json; NSPLIT=$D/wg.split.conf; NNAME=WireGuard;;
  esac
}
nat_running(){
  case "$1" in
    hy2) pidof hysteria >/dev/null 2>&1;;
    naive) pidof naive >/dev/null 2>&1;;
    wg) wg_up;;
    *) pidof xray >/dev/null 2>&1;;
  esac
}
nat_inst(){
  case "$1" in
    hy2) [ -x "$HYSTERIA_BIN" ];;
    naive) [ -x "$NAIVE_BIN" ];;
    wg) wg_inst;;
  esac
}
# One connectivity check through the protocol's own local entry (never through another protocol).
nat_probe_once(){
  case "$1" in
    hy2) _c=$(curl -s -o /dev/null -m 12 -w '%{http_code}' --socks5-hostname 127.0.0.1:10818 https://www.google.com/generate_204 2>/dev/null);;
    naive) _c=$(curl -s -o /dev/null -m 12 -w '%{http_code}' --socks5-hostname 127.0.0.1:10828 https://www.google.com/generate_204 2>/dev/null);;
    wg) _c=$(curl -4 -s -o /dev/null -m 12 -w '%{http_code}' --interface "$WGIF" https://www.google.com/generate_204 2>/dev/null);;
    *) _c=$(curl -s -o /dev/null -m 12 -w '%{http_code}' --socks5-hostname 127.0.0.1:10808 https://www.google.com/generate_204 2>/dev/null);;
  esac
  [ "$_c" = 204 ]
}
nat_probe(){
  if [ -n "${VLESS_AU_PROBE:-}" ]; then sh "$VLESS_AU_PROBE"; return $?; fi
  _n=0
  while [ $_n -lt "${VLESS_AU_PROBE_TRIES:-4}" ]; do
    nat_probe_once "$1" && return 0
    _n=$((_n+1)); sleep "${VLESS_AU_PROBE_PAUSE:-2}"
  done
  return 1
}
# DNS through the router (dnsmasq -> the protocol's own DNS path) must still answer once steering is on.
nat_dns_check(){
  if [ -n "${VLESS_AU_DNSCHECK:-}" ]; then sh "$VLESS_AU_DNSCHECK"; return $?; fi
  _n=0
  while [ $_n -lt 4 ]; do
    nslookup www.google.com 127.0.0.1 2>/dev/null | awk '/^Name:/{n=1} n&&/^Address/{f=1} END{exit !f}' && return 0
    _n=$((_n+1)); sleep 2
  done
  return 1
}
nat_reason(){
  case "$1" in
    wg) wg_reason;;
    *) nat_set "$1"; tr '\n' ' ' < "/tmp/aurora-restart-$NSVC.err" 2>/dev/null | sed 's/  */ /g; s/ $//';;
  esac
}
# Start (or restart) only this protocol's service. $2 = 1 also enables it at boot.
nat_start(){
  case "$1" in
    hy2) restart_init hysteria-client hysteria "$2";;
    naive) restart_init naive-client naive "$2";;
    wg) WGEN=$2; wg_restart;;
  esac
}
nat_steer(){ # $1 proto, $2 up|down
  nat_set "$1"
  if [ "$2" = up ]; then
    [ -f "$D/tproxy.disabled" ] && return 0
  fi
  if [ -n "${VLESS_AU_STEER:-}" ]; then sh "$VLESS_AU_STEER" "$NSP" "$2"; return $?; fi
  "$AURORA_SPLIT" "$NSP" "$2"
}
# Stop only this protocol: steering, service, boot flag.
nat_stop(){
  nat_steer "$1" down
  nat_set "$1"
  svc "$NSVC" 0
  [ "$1" = wg ] && { ip rule del oif "$WGIF" lookup 871 2>/dev/null; true; }
}
xray_enable(){ [ -x "$INITD/xray-client" ] && "$INITD/xray-client" enable >/dev/null 2>&1; true; }
xray_stop(){
  $D/tproxy.sh down 2>/dev/null
  svc xray-client 0
}
xray_rollback(){ # restore Xray's previous state after a failed start ($1 = previous protocol)
  cp $D/config.prev.json $D/config.json 2>/dev/null
  echo "$1" > $D/proto; echo "$MODE" > $D/mode
  if is_native "$1"; then xray_stop; else xrestart; au_tproxy; fi
  err "Xray did not start, config rolled back"
}
# After protocol $1 became active: stop every other protocol's service.
stop_others(){
  case "$1" in vless|socks|http) ;; *) xray_stop;; esac
  for _q in hy2 naive wg; do [ "$_q" = "$1" ] || { nat_stop "$_q"; }; done
}
# Files that belong to one native protocol (for a rollback that cannot touch the others).
nat_files(){
  case "$1" in
    hy2) echo "$HYD/client.yaml $HYD/client.yaml.prev $D/hy2.txt $HYD/server_ip";;
    naive) echo "$NAD/config.json $NAD/config.json.prev $D/naive.txt $NAD/server_ip";;
    wg) echo "$D/wg.json $D/wg.conf $D/wg.resolved $D/wg.server_ip";;
  esac
}
nat_bak(){ mkdir -p "$2"; for f in $(nat_files "$1"); do [ -e "$f" ] && cp -a "$f" "$2/$(echo "$f" | tr / _)"; done; true; }
nat_rst(){ for f in $(nat_files "$1"); do b="$2/$(echo "$f" | tr / _)"; if [ -e "$b" ]; then cp -a "$b" "$f"; else rm -f "$f"; fi; done; true; }
# The transparent listeners of the protocol's own client must exist before any traffic is steered to them.
nat_listening(){
  [ -n "${VLESS_AU_NOLISTENCHECK:-}" ] && return 0
  case "$1" in
    hy2) netstat -lnt 2>/dev/null | grep -q ':12356 ' && netstat -lnu 2>/dev/null | grep -q ':12355 ';;
    naive) netstat -lnt 2>/dev/null | grep -q ':12366 ';;
    *) return 0;;
  esac
}
# Bring protocol $1 up as the active one (its service, a connectivity check, its steering), then stop the others.
nat_activate(){
  nat_set "$1"
  NERR=""
  nat_inst "$1" || { NERR="$NNAME is not installed"; return 1; }
  [ -s "$NCFG" ] || { NERR="no saved $NNAME config"; return 1; }
  nat_start "$1" 1 || { NERR="$NNAME did not start: $(nat_reason "$1")"; return 1; }
  if ! nat_probe "$1"; then
    NERR="$NNAME started but has no connectivity: check the config and the server"
    return 1
  fi
  nat_listening "$1" || { NERR="$NNAME is running without its transparent listener (old config?): save the link again"; return 1; }
  nat_steer "$1" up || { NERR="could not set up the $NNAME steering rules"; return 1; }
  if ! nat_dns_check; then
    nat_steer "$1" down
    NERR="DNS does not work through $NNAME"
    return 1
  fi
  echo "$1" > $D/proto; PROTO=$1
  stop_others "$1"
  return 0
}
# Save (optional file $2) and switch to Hysteria/Naive/WireGuard. On any failure the previous
# files and the previous active protocol are restored; the other protocols are never touched.
native_switch(){
  P=$1; F=${2:-}
  nat_set "$P"
  PREVP=$PROTO
  B=/tmp/aurora-nbak-$$
  nat_bak "$P" "$B"
  if [ -n "$F" ]; then
    # err() exits; run the save in a subshell so that this protocol's files can still be rolled back
    ( store_proto "$P" "$F" ) || { nat_rst "$P" "$B"; rm -rf "$B"; exit 1; }
  fi
  if ! nat_activate "$P"; then
    reason=$NERR
    nat_rst "$P" "$B"
    if [ "$PREVP" = "$P" ]; then
      nat_start "$P" 1 >/dev/null 2>&1 && nat_steer "$P" up >/dev/null 2>&1
    else
      nat_stop "$P"
    fi
    rm -rf "$B"
    err "$reason; the previous setup was restored"
  fi
  rm -rf "$B"
  echo OK
}
# "mode ru|all" of a native protocol lives in its own split.conf; only that file and that service's steering change.
native_mode(){
  nat_set "$1"
  _cf=$("$AURORA_SPLIT" "$NSP" conf) || err "no split config for $NNAME"
  if grep -q '^mode ' "$_cf"; then sed -i "s/^mode .*/mode $2/" "$_cf"; else echo "mode $2" >> "$_cf"; fi
  nat_steer "$1" up || err "could not apply the new split rules"
  echo OK
}
# Re-apply the (already saved) config of the active native protocol: restart only its service.
native_reload(){
  nat_start "$1" 1 && nat_probe "$1" && nat_listening "$1" && nat_steer "$1" up
}
# Boot hook: wait for the active native protocol, check it, then steer. Fail open: no steering if it never works.
steer_boot(){
  is_native "$PROTO" || return 0
  [ -f "$D/tproxy.disabled" ] && return 0
  _n=0
  while [ $_n -lt "${VLESS_AU_BOOT_TRIES:-30}" ]; do
    if nat_running "$PROTO" && nat_listening "$PROTO" && nat_probe_once "$PROTO"; then nat_steer "$PROTO" up; return $?; fi
    _n=$((_n+1)); sleep "${VLESS_AU_BOOT_PAUSE:-3}"
  done
  logger -t aurora "steer-boot: $PROTO did not come up; transparent steering left off" 2>/dev/null || true
  return 1
}
# Steering table of the active protocol ("transparent mode").
steer_present(){
  case "$PROTO" in
    hy2) nft list table inet aurora_hy >/dev/null 2>&1;;
    naive) nft list table inet aurora_nv >/dev/null 2>&1;;
    wg) nft list table inet aurora_wg >/dev/null 2>&1;;
    *) nft list table inet xray >/dev/null 2>&1;;
  esac
}
gen(){ # $1 linkfile $2 mode $3 proto   (Xray family only: vless, socks, http)
  P=${3:-$PROTO}
  PREVP=$PROTO
  case "$P" in vless|socks|http) ;; *) err "gen: $P does not use Xray";; esac
  if [ "$P" = socks ] || [ "$P" = http ]; then
    if [ ! -s "$D/$P.json" ]; then
      [ "$P" = socks ] && err "Fill in the SOCKS5 fields first"
      err "Fill in the HTTP fields first"
    fi
    ucode $D/gen.uc --base "$2" > /tmp/vless.json 2>/tmp/vless.err || err "$(cat /tmp/vless.err)"
    merge_proxy_cfg "$P" /tmp/vless.json "$D/$P.json" /tmp/vless.j2
    mv /tmp/vless.j2 /tmp/vless.json
    H=$(jq -r '.address' "$D/$P.json")
    IP=$(resolve_host_ip "$H")
    case "$H" in
      *:*) ;;
      *) [ -n "$IP" ] || err "Could not resolve the server IP" ;;
    esac
    if [ -z "${VLESS_AU_SKIP_XRAY_TEST:-}" ]; then
      XRAY_LOCATION_ASSET=/usr/share/xray xray run -test -c /tmp/vless.json >/tmp/vless.err 2>&1 || err "Xray rejected the config: $(tail -3 /tmp/vless.err)"
    else
      jq -e . /tmp/vless.json >/dev/null 2>&1 || err "config is not JSON"
    fi
    cp $D/config.json $D/config.prev.json 2>/dev/null
    mv /tmp/vless.json $D/config.json
    [ -n "$IP" ] && echo "$IP" > $D/server_ip
    echo "$2" > $D/mode
    echo "$P" > $D/proto
    xrestart || xray_rollback "$PREVP"
    xray_enable
    au_tproxy
    stop_others "$P"
    echo OK
    return 0
  fi
  L=$(cat "$1" | tr -d '\r\n ')
  case "$L" in vless://*) ;; *) err "The link must start with vless://";; esac
  H=$(echo "$L" | sed -E 's#^vless://[^@]+@\[?([^]:/?#]+)\]?:.*#\1#')
  if echo "$H" | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then IP=$H
  else IP=$(nslookup "$H" 2>/dev/null | awk '/^Name:/{n=1} n&&/^Address/{print $NF}' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)
  fi
  [ -n "$IP" ] || err "Could not resolve the server IP $H"
  printf '%s\n' "$L" > /tmp/vless.link
  ucode $D/gen.uc /tmp/vless.link "$IP" "$2" > /tmp/vless.json 2>/tmp/vless.err || err "$(cat /tmp/vless.err)"
  if [ -z "${VLESS_AU_SKIP_XRAY_TEST:-}" ]; then
    XRAY_LOCATION_ASSET=/usr/share/xray xray run -test -c /tmp/vless.json >/tmp/vless.err 2>&1 || err "Xray rejected the config: $(tail -3 /tmp/vless.err)"
  else
    jq -e . /tmp/vless.json >/dev/null 2>&1 || err "config is not JSON"
  fi
  cp $D/config.json $D/config.prev.json 2>/dev/null
  mv /tmp/vless.json $D/config.json; mv /tmp/vless.link $D/link.txt; echo "$IP" > $D/server_ip; echo "$2" > $D/mode; echo "$P" > $D/proto
  xrestart || xray_rollback "$PREVP"
  xray_enable
  au_tproxy
  stop_others "$P"
  echo OK
}
store_vless(){
  L=$(cat "$1" | tr -d '\r\n ')
  case "$L" in vless://*) ;; *) err "The link must start with vless://";; esac
  printf '%s\n' "$L" > $D/link.txt
}
store_hy2(){
  L=$(cat "$1" | tr -d '\r\n ')
  printf '%s\n' "$L" > /tmp/hy2.link
  ucode $D/hy2.uc /tmp/hy2.link > /tmp/hy2.yaml 2>/tmp/hy2.err || err "$(cat /tmp/hy2.err)"
  mkdir -p $HYD; cp $HYD/client.yaml $HYD/client.yaml.prev 2>/dev/null
  mv /tmp/hy2.yaml $HYD/client.yaml; mv /tmp/hy2.link $D/hy2.txt
  # the server address stays outside the tunnel (steering bypass); keep the old one if DNS fails
  _h=$(awk -F'"' '/^server:/{h=$2; if (h ~ /^\[/) h=""; else sub(/:.*/,"",h); print h; exit}' $HYD/client.yaml)
  _ip=$(resolve_host_ip "$_h")
  if [ -n "$_ip" ]; then
    echo "$_ip" > $HYD/server_ip
    # Connect by address (SNI keeps the host name): the client never needs DNS, which
    # itself goes through the tunnel, to reconnect.
    case "$_h" in *[!0-9.]*)
      awk -v h="$_h" -v ip="$_ip" '
        /^server:/ && !d { sub(h, ip); d=1 }
        /^  sni: ""/ { print "  sni: \"" h "\""; next }
        { print }' $HYD/client.yaml > $HYD/client.yaml.new && mv $HYD/client.yaml.new $HYD/client.yaml;;
    esac
  fi
  return 0
}
store_naive(){
  L=$(cat "$1" | tr -d '\r\n ')
  case "$L" in naive+https://*@*) ;; *) err "The link must start with naive+https://";; esac
  U=$(echo "$L" | sed -E 's#^naive\+https://([^@]+)@.*#\1#')
  HP=$(echo "$L" | sed -E 's#^naive\+https://[^@]+@([^/?\#]+).*#\1#')
  NH=${HP%:*}; NP=${HP##*:}; [ "$NP" = "$HP" ] && NP=443
  if echo "$NH" | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then NIP=$NH
  else NIP=$(nslookup "$NH" 2>/dev/null | awk '/^Name:/{n=1} n&&/^Address/{print $NF}' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1); [ -n "$NIP" ] || NIP=$(cat $NAD/server_ip 2>/dev/null); fi
  [ -n "$NIP" ] || err "Could not resolve the Naive server $NH"
  mkdir -p $NAD; cp $NAD/config.json $NAD/config.json.prev 2>/dev/null
  jq -n --arg p "https://$U@$NH:$NP" --arg r "MAP $NH $NIP" '{listen:["socks://127.0.0.1:10828","redir://0.0.0.0:12366"],proxy:$p,"host-resolver-rules":$r}' > $NAD/config.json || err "jq"
  echo "$NIP" > $NAD/server_ip
  chmod 600 $NAD/config.json; printf '%s\n' "$L" > $D/naive.txt; chmod 600 $D/naive.txt
}
store_wg(){
  tr -d '\r' < "$1" > /tmp/wg.conf
  awk -F' *= *' '
    /^\[Peer\]/{np++} /^ *#/||NF<2{next}
    {k=tolower($1); gsub(/^ +| +$/,"",k); v=substr($0,index($0,"=")+1); gsub(/^ +| +$/,"",v)}
    k=="privatekey"{pk=v} k=="address"{ad=v} k=="mtu"{mtu=v}
    k=="publickey"{pub[np]=v} k=="presharedkey"{psk[np]=v} k=="endpoint"{ep[np]=v} k=="allowedips"{al[np]=v}
    function arr(x,  a,n,i,o){n=split(x,a,/ *, */);o="";for(i=1;i<=n;i++)if(a[i]!="")o=o (o?",":"") "\"" a[i] "\"";return "[" o "]"}
    END{ if(pk==""||np<1){print "bad" > "/dev/stderr"; exit 1}
      printf "{\"protocol\":\"wireguard\",\"settings\":{\"secretKey\":\"%s\",\"address\":%s,\"mtu\":%d,\"peers\":[", pk, arr(ad), (mtu?mtu:1420)
      for(i=1;i<=np;i++){ printf "%s{\"publicKey\":\"%s\",\"endpoint\":\"%s\",\"allowedIPs\":%s%s}", (i>1?",":""), pub[i], ep[i], arr(al[i]?al[i]:"0.0.0.0/0"), (psk[i]?",\"preSharedKey\":\"" psk[i] "\"":"") }
      print "]}}" }' /tmp/wg.conf > /tmp/wg.json 2>/dev/null || { rm -f /tmp/wg.conf; err "Does not look like a WireGuard config ([Interface] PrivateKey and [Peer] are required)"; }
  jq -e . /tmp/wg.json >/dev/null 2>&1 || { rm -f /tmp/wg.conf /tmp/wg.json; err "Could not parse the WireGuard config"; }
  umask 077; mv /tmp/wg.json $D/wg.json; mv /tmp/wg.conf $D/wg.conf
  _ep=$(jq -r '.settings.peers[0].endpoint // empty' $D/wg.json)
  _ip=$(resolve_host_ip "${_ep%:*}")
  [ -n "$_ip" ] && echo "$_ip" > $D/wg.server_ip
  return 0
}
# Resolve a hostname or IPv4 literal to an IPv4 address (for the tproxy bypass set).
# IPv6 literals return empty (the bypass set is IPv4-only).
resolve_host_ip(){
  H=$1
  if echo "$H" | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
    printf '%s\n' "$H"
    return 0
  fi
  # IPv6 literal (with or without brackets): no IPv4 to add to the bypass set.
  case "$H" in *:*) return 0;; esac
  nslookup "$H" 2>/dev/null | awk '/^Name:/{n=1} n&&/^Address/{print $NF}' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1
}

store_proxy(){
  # proto infile — JSON with address, port, optional user/pass;
  # for http also tls (bool), sni, allowInsecure (bool). Written 0600.
  P=$1
  case "$P" in socks|http) ;; *) err "store socks|http";; esac
  [ -s "$2" ] || err "enter an address and a port"
  jq -e . "$2" >/dev/null 2>&1 || err "could not read the settings"
  ADDR=$(jq -r '.address // empty' "$2")
  PORT=$(jq -r '.port // empty' "$2")
  [ -n "$ADDR" ] || err "enter an address"
  printf '%s' "$ADDR" | grep -q '[[:space:]]' && err "invalid address"
  [ "${#ADDR}" -le 253 ] || err "invalid address"
  case "$PORT" in ''|*[!0-9]*) err "enter a port from 1 to 65535";; esac
  [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || err "enter a port from 1 to 65535"
  USER=$(jq -r '.user // empty' "$2")
  PASS=$(jq -r '.pass // empty' "$2")
  [ "${#USER}" -le 256 ] && [ "${#PASS}" -le 256 ] || err "login or password is too long"
  OUT=/tmp/proxy-$P.json
  umask 077
  if [ "$P" = http ]; then
    TLS=$(jq -r 'if .tls==true or .tls=="1" or .tls==1 then "true" else "false" end' "$2")
    INS=$(jq -r 'if .allowInsecure==true or .allowInsecure=="1" or .allowInsecure==1 then "true" else "false" end' "$2")
    SNI=$(jq -r '.sni // empty' "$2")
    [ "${#SNI}" -le 253 ] || err "invalid SNI"
    jq -n --arg a "$ADDR" --argjson p "$PORT" --arg u "$USER" --arg w "$PASS" --argjson tls "$TLS" --arg s "$SNI" --argjson ins "$INS" \
      '{address:$a,port:$p,user:$u,pass:$w,tls:$tls,sni:$s,allowInsecure:$ins}' > "$OUT" || err "jq"
  else
    jq -n --arg a "$ADDR" --argjson p "$PORT" --arg u "$USER" --arg w "$PASS" \
      '{address:$a,port:$p,user:$u,pass:$w}' > "$OUT" || err "jq"
  fi
  chmod 600 "$OUT"
  mv "$OUT" "$D/$P.json"
  chmod 600 "$D/$P.json"
}

# proto base.json settings.json out.json — replace the "proxy" outbound (and,
# for http, send DNS over TCP, block QUIC, and send other UDP direct).
merge_proxy_cfg(){
  P=$1
  case "$P" in socks|http) ;; *) err "mergecfg socks|http";; esac
  [ -s "$2" ] && [ -s "$3" ] || err "no config"
  jq -e . "$2" >/dev/null 2>&1 && jq -e . "$3" >/dev/null 2>&1 || err "could not read the config"
  if [ "$P" = socks ]; then
    jq --slurpfile s "$3" '
      def server:
        {address:$s[0].address, port:($s[0].port|tonumber)} as $b
        | if (($s[0].user//"")!="" or ($s[0].pass//"")!="")
          then $b + {users:[{user:($s[0].user//""), pass:($s[0].pass//"")}]}
          else $b end;
      (.outbounds[] | select(.tag=="proxy")) |= {
        tag:"proxy", protocol:"socks",
        settings:{servers:[server]},
        streamSettings:{sockopt:{mark:255}}
      }
    ' "$2" > "$4" || err "jq"
  else
    jq --slurpfile s "$3" '
      def server:
        {address:$s[0].address, port:($s[0].port|tonumber)} as $b
        | if (($s[0].user//"")!="" or ($s[0].pass//"")!="")
          then $b + {users:[{user:($s[0].user//""), pass:($s[0].pass//"")}]}
          else $b end;
      def stream:
        {sockopt:{mark:255}} +
        (if $s[0].tls==true then
          {security:"tls", tlsSettings:{
            serverName:(if ($s[0].sni//"")!="" then $s[0].sni else $s[0].address end),
            allowInsecure:($s[0].allowInsecure==true)
          }}
         else {} end);
      (.outbounds[] | select(.tag=="proxy")) |= {
        tag:"proxy", protocol:"http",
        settings:{servers:[server]},
        streamSettings:stream
      }
      | .outbounds += [
          {tag:"dns-out",protocol:"dns",settings:{network:"tcp",address:"1.1.1.1",port:53}},
          {tag:"block",protocol:"blackhole"}
        ]
      | .dns = {servers:["tcp://1.1.1.1","tcp://8.8.8.8"],queryStrategy:"UseIPv4"}
      | .routing.rules = [
          {type:"field",inboundTag:["dns-in"],outboundTag:"dns-out"},
          {type:"field",network:"udp",port:"53",outboundTag:"dns-out"},
          {type:"field",network:"udp",port:"443",outboundTag:"block"}
        ] + .routing.rules[0:-1] + [
          {type:"field",network:"udp",outboundTag:"direct"}
        ] + .routing.rules[-1:]
    ' "$2" > "$4" || err "jq"
  fi
}

store_proto(){
  case "$1" in
    vless) store_vless "$2" ;;
    hy2) store_hy2 "$2" ;;
    naive) store_naive "$2" ;;
    wg) store_wg "$2" ;;
    socks|http) store_proxy "$1" "$2" ;;
    *) err "store vless|hy2|naive|wg|socks|http" ;;
  esac
}
do_src(){ # proto infile outfile fetch(0|1)
  # Input of a card's link field. An http(s) URL is a subscription: remember it
  # as the auto-update source and, with fetch=1, write the extracted link/config
  # to outfile. Anything else is copied to outfile and clears the source.
  P=$1
  au_ok_proto "$P" || err "src vless|hy2|naive|wg <infile> <outfile> <0|1>"
  c=$(tr -d '\r\n\t ' < "$2" | head -c 2048)
  case "$c" in
    http://*|https://*)
      if [ "$4" = 1 ]; then
        au_fetch "$c" "$2.fetch"
        au_extract "$2.fetch" "$P" "$3" || { rm -f "$2.fetch"; err "the response has no config for $P"; }
        rm -f "$2.fetch"
      fi
      au_src_set "$P" "$c" ;;
    *) cat "$2" > "$3"; au_src_clear "$P" ;;
  esac
  echo OK
}
do_update(){
  P=$1
  au_ok_proto "$P" || err "update vless|hy2|naive|wg"
  au_load "$P"
  URL=$(au_resolve_url "$P")
  if [ -z "$URL" ]; then
    echo "nothing to update: the saved connection link is not an http(s) subscription"
    return 0
  fi
  IN=/tmp/vless-au-$P.in
  OUT=/tmp/vless-au-$P.out
  au_fetch "$URL" "$IN"
  au_extract "$IN" "$P" "$OUT" || { rm -f "$IN"; err "the response has no config for $P"; }
  rm -f "$IN"
  CUR=$(au_current_file "$P")
  if [ -f "$CUR" ] && au_same "$P" "$CUR" "$OUT"; then
    rm -f "$OUT"
    echo "no changes"
    return 0
  fi
  B=/tmp/vless-au-bak-$$
  au_backup "$B" "$P"
  if [ "$PROTO" = "$P" ]; then
    # P is the active protocol: apply the new config to P's own service only.
    if [ "$P" = naive ] && [ ! -x /usr/bin/naive ] && [ -z "${VLESS_AU_APPLY:-}" ]; then
      rm -rf "$B" "$OUT"
      err "Install naive first: /usr/libexec/vpn-panel/install-naive.sh"
    fi
    if [ -n "${VLESS_AU_APPLY:-}" ]; then
      if ! sh "$VLESS_AU_APPLY" "$P" "$OUT"; then
        au_restore "$B" "$P"; au_reapply "$P"
        rm -rf "$B" "$OUT"
        err "could not apply the update, config rolled back"
      fi
    else
      # Child process: store/gen call err() and exit; the parent can still roll back.
      case "$P" in
        vless) cmd=save ;;
        *) cmd=reload-with ;;
      esac
      if ! "$0" "$cmd" "$OUT" ${cmd:+$P} >/tmp/vless-au-apply.out 2>&1; then
        au_restore "$B" "$P"; au_reapply "$P"
        rm -rf "$B" "$OUT"
        err "could not apply the update, config rolled back: $(cat /tmp/vless-au-apply.out 2>/dev/null)"
      fi
    fi
    if ! au_probe; then
      au_restore "$B" "$P"
      au_reapply "$P"
      rm -rf "$B" "$OUT"
      err "no internet after the update, config rolled back"
    fi
    [ "$P" = vless ] && au_tproxy
    rm -rf "$B" "$OUT"
    echo OK
  else
    if ! "$0" store "$P" "$OUT" >/tmp/vless-au-store.out 2>&1; then
      au_restore "$B" "$P"
      rm -rf "$B" "$OUT"
      err "could not save the update, files rolled back: $(cat /tmp/vless-au-store.out 2>/dev/null)"
    fi
    rm -rf "$B" "$OUT"
    echo "Saved without switching (now $PROTO)"
  fi
}
# Re-apply a protocol's restored files to that protocol's own service (nothing else is restarted).
au_reapply(){
  case "$1" in
    vless) xrestart; au_tproxy;;
    *) is_native "$1" && native_reload "$1";;
  esac
  return 0
}
# ASCII uppercase for log lines mixed into the Russian banner. Cyrillic is
# already uppercase in the messages below; tr leaves it unchanged.
upper(){ printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'; }
# Set by the Xray restart: when it fails while transparent mode is on, a detached
# "recover" keeps trying to bring Xray and transparent mode back.
RECOVER_ON_FAIL=""
spawn_recover(){
  if [ -n "${VLESS_AU_RECOVER_CMD:-}" ]; then sh "$VLESS_AU_RECOVER_CMD"; return 0; fi
  setsid sh "$0" recover >/dev/null 2>&1 </dev/null &
}
fail_restart(){
  _hint=$2
  if [ -n "$RECOVER_ON_FAIL" ] && [ ! -f "$D/tproxy.disabled" ]; then
    spawn_recover
    _hint="$_hint. AUTOMATIC RECOVERY HAS STARTED: XRAY AND TRANSPARENT MODE WILL COME BACK BY THEMSELVES WITHIN A COUPLE OF MINUTES"
  fi
  printf 'ERROR: %s\n' "$1"
  printf 'HINT: %s\n' "$_hint"
  exit 1
}
# Last "Failed to start" reason Xray wrote to the log after $1 (a marker line taken before the restart).
xray_log_reason(){
  if [ -n "${VLESS_AU_LOGREAD:-}" ]; then _l=$(sh "$VLESS_AU_LOGREAD" 2>/dev/null)
  else
    _all=$(logread -e xray 2>/dev/null)
    if [ -n "$1" ] && printf '%s\n' "$_all" | grep -qF -- "$1"; then
      _l=$(printf '%s\n' "$_all" | awk -v m="$1" 'f{print} index($0,m){f=1}')
    else _l=$_all; fi
  fi
  printf '%s\n' "$_l" | grep -E 'Failed to start|panic|fatal' | tail -1 | sed -e 's/.*Failed to start: //' -e 's/.* > //' | cut -c1-160
}
busy_ports(){
  if [ -n "${VLESS_AU_PORTS_BUSY:-}" ] && [ "$VLESS_AU_PORTS_BUSY" != 1 ]; then
    printf '%s' "$VLESS_AU_PORTS_BUSY"
    return 0
  fi
  out=""
  n=$(netstat -lnt 2>/dev/null || true)
  u=$(netstat -lnu 2>/dev/null || true)
  printf '%s\n' "$n" | grep -q ':10808 ' && out="$out 10808/TCP"
  printf '%s\n' "$n" | grep -q ':12346 ' && out="$out 12346/TCP"
  printf '%s\n' "$u" | grep -q ':12345 ' && out="$out 12345/UDP"
  if [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  printf '%s' " 10808/TCP 12346/TCP 12345/UDP"
}
# $1 process name, $2 seconds. 0 if the process is up now and is still the same
# process (same pid) after the wait, i.e. it did not crash or respawn.
proc_stable(){
  p1=$(pidof "$1" 2>/dev/null) || return 1
  [ -n "$p1" ] || return 1
  [ "$2" -gt 0 ] 2>/dev/null && sleep "$2"
  p2=$(pidof "$1" 2>/dev/null) || return 1
  [ "$p1" = "$p2" ]
}
# $1 init script name, $2 process name, $3 "0" to skip enabling the service at boot
# (used for a daemon that belongs to a protocol that is not the active one).
# Full restart, then wait until the process is up and stays up for STABLE_SECS seconds.
restart_init(){
  name=$1
  proc=$2
  en=${3:-1}
  errf=/tmp/aurora-restart-$name.err
  : > "$errf"
  if [ -n "${VLESS_AU_SVC_RESTART:-}" ]; then
    sh "$VLESS_AU_SVC_RESTART" "$name" "$proc"
    return $?
  fi
  if [ ! -x "$INITD/$name" ]; then
    echo "no script $INITD/$name" > "$errf"
    return 3
  fi
  [ "$en" = 0 ] || "$INITD/$name" enable >>"$errf" 2>&1 || true
  "$INITD/$name" restart >>"$errf" 2>&1 || true
  i=0
  while [ "$i" -lt 15 ]; do
    if pidof "$proc" >/dev/null 2>&1; then
      proc_stable "$proc" "$STABLE_SECS" && return 0
      echo "process $proc started and exited right away" >> "$errf"
      return 1
    fi
    i=$((i+1))
    sleep 1
  done
  return 1
}
require_bin(){ # $1 path, $2 short name (XRAY|HYSTERIA|NAIVE)
  if [ ! -e "$1" ]; then
    case "$2" in
      HYSTERIA) fail_restart "FILE MISSING: $(upper "$1")" "INSTALL HYSTERIA IN /USR/BIN OR CONNECT ANOTHER PROTOCOL";;
      NAIVE) fail_restart "FILE MISSING: $(upper "$1")" "INSTALL NAIVE WITH /USR/LIBEXEC/VPN-PANEL/INSTALL-NAIVE.SH";;
      *) fail_restart "FILE MISSING: $(upper "$1")" "INSTALL XRAY IN /USR/BIN AND THE GEOIP/GEOSITE FILES IN /USR/SHARE/XRAY";;
    esac
  fi
  if [ ! -x "$1" ]; then
    fail_restart "NO PERMISSION TO START $(upper "$1")" "RUN CHMOD 755 $(upper "$1") AND RESTART AS ROOT"
  fi
}
# Fully restart the daemons the active connection needs: always Xray
# (stop, wait for ports, start), plus Hysteria or Naive when that protocol is connected.
# Each restart_* below ends the whole script through fail_restart on failure.
# $HYEN / $NAEN: 1 when that daemon belongs to the active protocol (then it is
# also enabled at boot), 0 when it is restarted on its own.
restart_hysteria(){
  if ! restart_init hysteria-client hysteria "$HYEN"; then
    e=$(tr '\n' ' ' < /tmp/aurora-restart-hysteria-client.err 2>/dev/null || true)
    case "$e" in
      *no\ script*)
        fail_restart "SCRIPT MISSING: /ETC/INIT.D/HYSTERIA-CLIENT" "REINSTALL THE VPN-PANEL-GL-INET PACKAGE: IT PROVIDES THE START SCRIPT"
        ;;
    esac
    msg="HYSTERIA DID NOT START"
    [ -n "$e" ] && msg="$msg: $(upper "$e")"
    fail_restart "$msg" "CHECK /ETC/HYSTERIA/CLIENT.YAML AND LOGREAD -E HYSTERIA, THEN RESTART AGAIN"
  fi
}
restart_naive(){
  if ! restart_init naive-client naive "$NAEN"; then
    e=$(tr '\n' ' ' < /tmp/aurora-restart-naive-client.err 2>/dev/null || true)
    case "$e" in
      *no\ script*)
        fail_restart "SCRIPT MISSING: /ETC/INIT.D/NAIVE-CLIENT" "REINSTALL THE VPN-PANEL-GL-INET PACKAGE: IT PROVIDES THE START SCRIPT"
        ;;
    esac
    msg="NAIVE DID NOT START"
    [ -n "$e" ] && msg="$msg: $(upper "$e")"
    fail_restart "$msg" "CHECK /ETC/NAIVE/CONFIG.JSON AND LOGREAD -E NAIVE, THEN RESTART AGAIN"
  fi
}
# Bring the native WireGuard service up. wg_restart returns 0/1 and leaves the
# reason in the err file; restart_wireguard reports a failure as a banner.
wg_errf=/tmp/aurora-restart-wireguard-client.err
wg_reason(){ tr '\n' ' ' < "$wg_errf" 2>/dev/null | sed 's/  */ /g; s/ $//'; }
wg_restart(){
  : > "$wg_errf"
  if [ -n "${VLESS_AU_SVC_RESTART:-}" ]; then
    sh "$VLESS_AU_SVC_RESTART" wireguard-client wireguard || return 1
    wg_up; return $?
  fi
  if [ ! -x "$INITD/wireguard-client" ]; then
    echo "no script $INITD/wireguard-client" > "$wg_errf"
    return 3
  fi
  [ "${WGEN:-1}" = 0 ] || "$INITD/wireguard-client" enable >>"$wg_errf" 2>&1 || true
  "$INITD/wireguard-client" restart >>"$wg_errf" 2>&1 || true
  wg_up && return 0
  [ -s "$wg_errf" ] || echo "interface $WGIF did not come up" > "$wg_errf"
  return 1
}
restart_wireguard(){
  if ! wg_restart; then
    e=$(wg_reason)
    case "$e" in
      *no\ script*)
        fail_restart "SCRIPT MISSING: /ETC/INIT.D/WIREGUARD-CLIENT" "REINSTALL THE VPN-PANEL-GL-INET PACKAGE: IT PROVIDES THE START SCRIPT"
        ;;
    esac
    msg="WIREGUARD DID NOT START"
    [ -n "$e" ] && msg="$msg: $(upper "$e")"
    fail_restart "$msg" "CHECK /ETC/XRAY/WG.JSON AND LOGREAD -E WIREGUARD, THEN RESTART AGAIN"
  fi
}
restart_xray(){
  [ -f "$D/tproxy.disabled" ] || RECOVER_ON_FAIL=1
  _mark=""
  [ -z "${VLESS_AU_LOGREAD:-}" ] && _mark=$(logread -e xray 2>/dev/null | tail -n 1 | cut -c1-120)
  if ! xrestart; then
    lr=$(xray_log_reason "$_mark")
    errf=$(tail -c 400 /tmp/xray-restart.err 2>/dev/null | tr '\n' ' ')
    case "$errf $lr" in
      *[Pp]ermission\ denied*)
        fail_restart "NO PERMISSION TO START XRAY" "RESTART AS ROOT AND CHECK CHMOD 755 $(upper "$XRAY_BIN") AND THE OWNER OF /ETC/XRAY"
        ;;
      *[Aa]ddress\ already\ in\ use*)
        bp=$(printf '%s' "$lr" | sed -n 's/.*:\([0-9][0-9]*\): bind.*/\1/p')
        [ -n "$bp" ] && bp="$bp/TCP" || bp=$(busy_ports | sed 's/^ *//')
        fail_restart "PORT IN USE: $bp" "THE PORT IS STILL HELD BY CONNECTIONS OF THE OLD XRAY PROCESS: WAIT ABOUT A MINUTE AND RESTART AGAIN; IF IT PERSISTS, FIND THE PROCESS WITH NETSTAT -LNTUP AND STOP IT"
        ;;
    esac
    if xports_busy; then
      fail_restart "PORT IN USE: $(busy_ports | sed 's/^ *//')" "FIND THE PROCESS WITH NETSTAT -LNTUP, STOP IT AND RESTART AGAIN"
    fi
    extra=""
    [ -n "$lr" ] && extra=": $(upper "$lr")"
    [ -z "$extra" ] && [ -n "$errf" ] && extra=": $(upper "$errf")"
    fail_restart "XRAY DID NOT START${extra}" "CHECK LOGREAD -E XRAY, FIX THE CAUSE AND RESTART AGAIN"
  fi
  if ! proc_stable xray "$STABLE_SECS"; then
    fail_restart "XRAY STARTED AND THEN EXITED" "CHECK LOGREAD -E XRAY, FIX THE CAUSE AND RESTART AGAIN"
  fi
  if [ ! -f "$D/tproxy.disabled" ] && ! nft list table inet xray >/dev/null 2>&1; then
    fail_restart "TRANSPARENT MODE IS NOT ACTIVE: NFT TABLE INET XRAY IS MISSING" "RUN /ETC/XRAY/TPROXY.SH UP OR PRESS «ENABLE», THEN CHECK NFT LIST TABLE INET XRAY"
  fi
  rm -f "$EGRESS_CACHE"
}
# Config/binary/test checks shared by every Xray restart.
check_xray(){
  if [ ! -s "$D/config.json" ]; then
    fail_restart "CONFIG FILE MISSING: /ETC/XRAY/CONFIG.JSON" "PRESS «CONNECT» ON THE CHOSEN PROTOCOL TO CREATE THE CONFIG, THEN RESTART AGAIN"
  fi
  if [ -z "${VLESS_AU_SKIP_XRAY_TEST:-}" ]; then
    if ! XRAY_LOCATION_ASSET=${VLESS_XRAY_ASSET:-/usr/share/xray} "$XRAY_BIN" run -test -c "$D/config.json" >/tmp/vless.err 2>&1; then
      why=$(tail -c 400 /tmp/vless.err 2>/dev/null | tr '\n' ' ')
      case "$why" in
        *[Pp]ermission\ denied*)
          fail_restart "NO PERMISSION FOR THE CONFIG OR TO START XRAY" "RESTART AS ROOT AND CHECK THE PERMISSIONS OF /ETC/XRAY/CONFIG.JSON AND $(upper "$XRAY_BIN")"
          ;;
        *)
          fail_restart "XRAY REJECTED THE CONFIG: $(upper "$why")" "FIX THE CONFIG WITH XRAY RUN -TEST -C /ETC/XRAY/CONFIG.JSON, PRESS «CONNECT» AGAIN AND RESTART AGAIN"
          ;;
      esac
    fi
  fi
}
do_restart(){
  rm -f /tmp/xray-restart.err
  case "$PROTO" in
    hy2) require_bin "$HYSTERIA_BIN" HYSTERIA; nat_steer hy2 down; HYEN=1; restart_hysteria; nat_steer hy2 up;;
    naive) require_bin "$NAIVE_BIN" NAIVE; nat_steer naive down; NAEN=1; restart_naive; nat_steer naive up;;
    wg) wg_inst || fail_restart "WIREGUARD IS NOT INSTALLED" "INSTALL THE PACKAGES: OPKG UPDATE && OPKG INSTALL KMOD-WIREGUARD WIREGUARD-TOOLS"
        nat_steer wg down; WGEN=1; restart_wireguard; nat_steer wg up;;
    *) require_bin "$XRAY_BIN" XRAY; check_xray; restart_xray;;
  esac
  echo OK
}
# Restart exactly one service: xray | naive | hysteria | wireguard. Each is its own
# service; the active protocol is never changed and no other service is touched.
do_restart_svc(){
  rm -f /tmp/xray-restart.err
  case "$1" in
    xray)
      require_bin "$XRAY_BIN" XRAY
      check_xray
      restart_xray;;
    wireguard)
      # Native WireGuard service only: Xray and transparent mode are never touched.
      wg_inst || fail_restart "WIREGUARD IS NOT INSTALLED" "INSTALL THE PACKAGES: OPKG UPDATE && OPKG INSTALL KMOD-WIREGUARD WIREGUARD-TOOLS"
      [ -s "$D/wg.json" ] || fail_restart "FILE MISSING: /ETC/XRAY/WG.JSON" "PASTE A WIREGUARD CONFIG INTO THE FIELD AND PRESS «CONNECT WIREGUARD»"
      WGEN=0; [ "$PROTO" = wg ] && WGEN=1
      [ "$PROTO" = wg ] && nat_steer wg down
      restart_wireguard
      [ "$PROTO" = wg ] && nat_steer wg up;;
    hysteria)
      require_bin "$HYSTERIA_BIN" HYSTERIA
      [ -s "$HYD/client.yaml" ] || fail_restart "FILE MISSING: /ETC/HYSTERIA/CLIENT.YAML" "PASTE A HYSTERIA2 LINK INTO THE FIELD AND PRESS «CONNECT HYSTERIA2»"
      HYEN=0; [ "$PROTO" = hy2 ] && HYEN=1
      [ "$PROTO" = hy2 ] && nat_steer hy2 down
      restart_hysteria
      [ "$PROTO" = hy2 ] && nat_steer hy2 up;;
    naive)
      require_bin "$NAIVE_BIN" NAIVE
      [ -s "$NAD/config.json" ] || fail_restart "FILE MISSING: /ETC/NAIVE/CONFIG.JSON" "PASTE A NAIVE LINK INTO THE FIELD AND PRESS «CONNECT NAIVE»"
      NAEN=0; [ "$PROTO" = naive ] && NAEN=1
      [ "$PROTO" = naive ] && nat_steer naive down
      restart_naive
      [ "$PROTO" = naive ] && nat_steer naive up;;
    *) fail_restart "UNKNOWN SERVICE" "CHOOSE XRAY, NAIVE, HYSTERIA OR WIREGUARD";;
  esac
  echo OK
}
# Public address as seen from the far end of the active tunnel.
# 127.0.0.1:10808 is Xray's SOCKS inbound. Its proxy outbound is the next hop
# (VLESS, Hysteria on 10818, Naive on 10828, WireGuard, or an upstream SOCKS/HTTP
# proxy, which may itself chain further). An echo request through that inbound
# therefore leaves from the last hop. The saved server address is the first hop
# and is never used here.
egress_valid(){
  printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && return 0
  printf '%s' "$1" | grep -Eq '^[0-9A-Fa-f:]+:[0-9A-Fa-f:]+$' && return 0
  return 1
}
# One probe with a 3 s limit; a good answer is cached for 60 s per
# (xray pid, protocol, config mtime), so page loads do not hammer the tunnel.
egress_key(){
  nat_set "$PROTO" 2>/dev/null
  case "$PROTO" in
    hy2|naive|wg) _cf=$NCFG;; *) _cf=$D/config.json;;
  esac
  printf '%s|%s' "$PROTO" "$(stat -c %Y "$_cf" 2>/dev/null)"
}
# Public address through the active protocol's own entry (never through another protocol).
egress_fetch(){
  case "$PROTO" in
    hy2) curl -fsS -m 3 --socks5-hostname 127.0.0.1:10818 https://api.ipify.org 2>/dev/null;;
    naive) curl -fsS -m 3 --socks5-hostname 127.0.0.1:10828 https://api.ipify.org 2>/dev/null;;
    wg) curl -4 -fsS -m 3 --interface "$WGIF" https://api.ipify.org 2>/dev/null;;
    *) curl -fsS -m 3 --socks5-hostname 127.0.0.1:10808 https://api.ipify.org 2>/dev/null;;
  esac
}
# curl through the ACTIVE protocol's own local entry (never through another protocol).
# $1 = proto, the remaining arguments go to curl. Used by the panel Test/Speed buttons and by health.
entry_curl(){
  _ep=$1; shift
  case "$_ep" in
    hy2) curl --socks5-hostname 127.0.0.1:10818 "$@";;
    naive) curl --socks5-hostname 127.0.0.1:10828 "$@";;
    wg) curl -4 --interface "$WGIF" "$@";;
    *) curl --socks5-hostname 127.0.0.1:10808 "$@";;
  esac
}
# vless.sh probe 204|youtube|ip|speed: what the panel's Test and Speed buttons measure, for the active protocol.
do_probe(){
  case "$1" in
    204) entry_curl "$PROTO" -s -o /dev/null -m 10 -w '%{http_code} %{time_total}' https://www.google.com/generate_204 2>/dev/null;;
    youtube) entry_curl "$PROTO" -s -o /dev/null -m 10 -w '%{http_code}' https://www.youtube.com 2>/dev/null;;
    ip) entry_curl "$PROTO" -s -m 8 https://api.ipify.org 2>/dev/null;;
    speed) entry_curl "$PROTO" -s -o /dev/null -m 20 -w '%{speed_download} %{size_download}' 'https://speed.cloudflare.com/__down?bytes=50000000' 2>/dev/null;;
    *) err "probe 204|youtube|ip|speed";;
  esac
}
# vless.sh health: does the transparent mode really pass traffic for the active protocol?
#   off     steering is not installed (direct internet)
#   down    steering is on but the active protocol's service is not running
#   broken  service runs but a connection through its own entry fails
#   ok      traffic passes
# A good or bad answer is cached for 20 s per (protocol, config mtime) so page loads stay fast.
do_health(){
  steer_present || { echo off; return 0; }
  nat_running "$PROTO" || { echo down; return 0; }
  _hk="$PROTO|$(stat -c %Y "$D/proto" 2>/dev/null)"
  _hc=${VLESS_HEALTH_CACHE:-/tmp/aurora-health}
  if [ -f "$_hc" ]; then
    _now=$(date +%s); _mt=$(stat -c %Y "$_hc" 2>/dev/null || echo 0)
    if [ $((_now - _mt)) -lt 20 ] && [ "$(sed -n 1p "$_hc")" = "$_hk" ]; then sed -n 2p "$_hc"; return 0; fi
  fi
  _r=broken
  if [ -n "${VLESS_AU_PROBE:-}" ]; then
    sh "$VLESS_AU_PROBE" && _r=ok
  else
    _c=$(entry_curl "$PROTO" -s -o /dev/null -m 4 -w '%{http_code}' https://www.google.com/generate_204 2>/dev/null)
    [ "$_c" = 204 ] && _r=ok
  fi
  printf '%s\n%s\n' "$_hk" "$_r" > "$_hc" 2>/dev/null
  echo "$_r"
}
egress_ip(){
  if [ -n "${VLESS_AU_EGRESS:-}" ]; then
    ip=$(sh "$VLESS_AU_EGRESS" 2>/dev/null | tr -d '\r\n\t ') || true
    egress_valid "$ip" || return 1
    printf '%s\n' "$ip"
    return 0
  fi
  nat_running "$PROTO" || return 1
  key=$(egress_key)
  if [ -f "$EGRESS_CACHE" ]; then
    now=$(date +%s); mt=$(stat -c %Y "$EGRESS_CACHE" 2>/dev/null || echo 0)
    if [ $((now - mt)) -lt 60 ] && [ "$(sed -n 1p "$EGRESS_CACHE")" = "$key" ]; then
      ip=$(sed -n 2p "$EGRESS_CACHE")
      if egress_valid "$ip"; then printf '%s\n' "$ip"; return 0; fi
    fi
  fi
  ip=$(egress_fetch | tr -d '\r\n\t ') || ip=
  egress_valid "$ip" || return 1
  printf '%s\n%s\n' "$key" "$ip" > "$EGRESS_CACHE" 2>/dev/null
  printf '%s\n' "$ip"
}
MODE=$(cat $D/mode 2>/dev/null || echo ru)
case "$1" in
save) store_vless "$2"; gen $D/link.txt "$MODE" vless;;
hy2save) native_switch hy2 "$2";;
naivesave)
  [ -x "$NAIVE_BIN" ] || err "Install naive first: /usr/libexec/vpn-panel/install-naive.sh"
  native_switch naive "$2";;
wgsave) native_switch wg "$2";;
reload-with) store_proto "$3" "$2"; is_native "$3" && { native_reload "$3" || err "$3 did not come up with the new config"; }; echo OK;;
sockssave) store_proxy socks "$2"; gen $D/link.txt "$MODE" socks;;
httpsave) store_proxy http "$2"; gen $D/link.txt "$MODE" http;;
store) store_proto "$2" "$3"; echo OK;;
mergecfg) merge_proxy_cfg "$2" "$3" "$4" "$5"; echo OK;;
proto) case "$2" in
    vless|socks|http) gen $D/link.txt "$MODE" "$2";;
    hy2|naive|wg) native_switch "$2";;
    *) err "proto vless|hy2|naive|wg|socks|http";;
  esac;;
mode) case "$2" in ru|all) ;; *) err "mode ru|all";; esac
  if is_native "$PROTO"; then native_mode "$PROTO" "$2"; else gen $D/link.txt "$2"; fi;;
on) rm -f $D/tproxy.disabled
  if is_native "$PROTO"; then
    nat_running "$PROTO" || { nat_start "$PROTO" 1 || err "$(nat_reason "$PROTO")"; }
    nat_steer "$PROTO" up || err "could not set up the steering rules"
  else
    xray_enable; xrestart || err "Xray did not start"
  fi
  echo OK;;
off) touch $D/tproxy.disabled
  if is_native "$PROTO"; then nat_steer "$PROTO" down; else $D/tproxy.sh down; fi
  echo OK;;
steer-boot) steer_boot;;
reactivate) # after an upgrade: rebuild the active native protocol's own config from its saved link and bring it up
  case "$PROTO" in
    hy2) native_switch hy2 "$D/hy2.txt";;
    naive) native_switch naive "$D/naive.txt";;
    wg) native_switch wg "$D/wg.conf";;
    *) exit 0;;
  esac;;
install) exec ${VLESS_INSTALL_CLIENT:-/usr/libexec/vpn-panel/install-client.sh} start "$2";;
install-status) exec ${VLESS_INSTALL_CLIENT:-/usr/libexec/vpn-panel/install-client.sh} status "$2";;
client-update) exec /usr/libexec/vpn-panel/client-update.sh "$2" "${3:-check}";;
restart) do_restart;;
restart-svc) do_restart_svc "$2";;
recover)
  # Detached helper started after a failed Xray restart: keep trying until Xray
  # listens again (xrestart switches transparent mode back on), then stop.
  mkdir "$RECOVER_LOCK" 2>/dev/null || exit 0
  trap 'rmdir "$RECOVER_LOCK" 2>/dev/null' EXIT
  n=0
  while [ $n -lt 6 ]; do
    [ -f "$D/tproxy.disabled" ] && exit 0
    xrestart && { au_tproxy; exit 0; }
    n=$((n+1))
  done;;
egress) egress_ip || exit 1;;
probe) do_probe "$2";;
health) do_health;;
status)
  echo "running=$(pidof xray >/dev/null && echo 1 || echo 0)"
  echo "hysteria=$(pidof hysteria >/dev/null && echo 1 || echo 0)"
  echo "naive=$(pidof naive >/dev/null && echo 1 || echo 0)"
  echo "wireguard=$(wg_up && echo 1 || echo 0)"
  echo "inst_xray=$([ -x "$XRAY_BIN" ] && echo 1 || echo 0)"
  echo "inst_hysteria=$([ -x "$HYSTERIA_BIN" ] && echo 1 || echo 0)"
  echo "inst_naive=$([ -x "$NAIVE_BIN" ] && echo 1 || echo 0)"
  echo "inst_wireguard=$(wg_inst && echo 1 || echo 0)"
  echo "wg_conf=$([ -s "$D/wg.json" ] && echo 1 || echo 0)"
  echo "tproxy=$(steer_present && echo 1 || echo 0)"
  echo "active_up=$(nat_running "$PROTO" && echo 1 || echo 0)"
  SM=$MODE
  if is_native "$PROTO"; then nat_set "$PROTO"; SM=$(sed 's/#.*//' "$NSPLIT" 2>/dev/null | awk '$1=="mode"{m=$2} END{print (m=="all"?"all":"ru")}'); fi
  echo "mode=$SM"; echo "proto=$PROTO"; SIPF=$D/server_ip
  case "$PROTO" in hy2) SIPF=$HYD/server_ip;; naive) SIPF=$NAD/server_ip;; wg) SIPF=$D/wg.server_ip;; esac
  echo "server_ip=$(cat "$SIPF" 2>/dev/null)";;
autoset)
  au_save_conf "$2" "$3" "$4" || err "autoset <proto> <0|1> <1h|6h|24h>"
  echo OK;;
src) do_src "$2" "$3" "$4" "$5";;
update) do_update "$2";;
*) err "usage";;
esac
