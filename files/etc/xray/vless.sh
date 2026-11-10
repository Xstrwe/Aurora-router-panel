#!/bin/sh
# vless.sh save <linkfile> | hy2save <linkfile> | naivesave <linkfile> | wgsave <conffile>
#         | store vless|hy2|naive|wg <file> | proto vless|hy2|naive|wg | mode ru|all
#         | on | off | status | autoset <proto> <0|1> <url> <1h|6h|24h>
#         | update <proto>
D=${VLESS_PANEL_DIR:-/etc/xray}
HYD=${VLESS_HYSTERIA_DIR:-/etc/hysteria}
NAD=${VLESS_NAIVE_DIR:-/etc/naive}
AU_LIB=${VLESS_AU_LIB:-/usr/libexec/vless-panel/autoupdate-lib.sh}
err(){ echo "ERROR: $*"; exit 1; }
PROTO=$(cat $D/proto 2>/dev/null || echo vless)
# shellcheck disable=SC1090
[ -f "$AU_LIB" ] && . "$AU_LIB"
svc(){ [ -x /etc/init.d/$1 ] || return 0; if [ "$2" = 1 ]; then /etc/init.d/$1 enable >/dev/null 2>&1; /etc/init.d/$1 restart >/dev/null 2>&1; else /etc/init.d/$1 stop >/dev/null 2>&1; /etc/init.d/$1 disable >/dev/null 2>&1; fi; }
xports_busy(){ # 0 if any of tcp 10808/12346 or udp 12345 is still bound
  netstat -lnt 2>/dev/null | grep -qE ':(10808|12346) ' && return 0
  netstat -lnu 2>/dev/null | grep -qE ':12345 ' && return 0
  return 1
}
xports_up(){ # 0 when both tcp 10808 and 12346 listen
  _n=$(netstat -lnt 2>/dev/null)
  echo "$_n" | grep -q ':10808 ' && echo "$_n" | grep -q ':12346 '
}
xrestart(){
  if [ -n "${VLESS_AU_XRESTART:-}" ]; then sh "$VLESS_AU_XRESTART"; return $?; fi
  /etc/init.d/xray-client stop >/dev/null 2>&1
  # wait up to 10s for xray to exit, then kill it
  i=0; while [ $i -lt 10 ] && pidof xray >/dev/null; do sleep 1; i=$((i+1)); done
  pidof xray >/dev/null && { killall -9 xray >/dev/null 2>&1; sleep 1; }
  # wait until the listen ports are released (a second instance would fail to bind)
  i=0; while [ $i -lt 10 ] && xports_busy; do sleep 1; i=$((i+1)); done
  /etc/init.d/xray-client start >/dev/null 2>&1
  i=0; while [ $i -lt 15 ]; do
    pidof xray >/dev/null && xports_up && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}
hyup(){ [ "$1" = hy2 ] && svc hysteria-client 1 || svc hysteria-client 0; [ "$1" = naive ] && svc naive-client 1 || svc naive-client 0; }
au_tproxy(){
  [ -f $D/tproxy.disabled ] && return 0
  if [ -n "${VLESS_AU_TPROXY:-}" ]; then sh "$VLESS_AU_TPROXY" up; return $?; fi
  $D/tproxy.sh up
}
au_probe(){
  if [ -n "${VLESS_AU_PROBE:-}" ]; then sh "$VLESS_AU_PROBE"; return $?; fi
  code=$(curl -s -o /dev/null -m 12 -w '%{http_code}' --socks5-hostname 127.0.0.1:10808 https://www.google.com/generate_204 2>/dev/null)
  [ "$code" = 204 ]
}
au_fetch(){
  case "$1" in http://*|https://*) ;; *) err "ссылка автообновления должна начинаться с http:// или https://";; esac
  if [ -n "${VLESS_AU_CURL:-}" ]; then
    sh "$VLESS_AU_CURL" "$1" "$2" || err "не удалось скачать обновление"
  else
    curl -fL --max-time 25 --max-filesize 1048576 -A 'vless-router-panel-autoupdate/1.3.0' -o "$2" "$1" || err "не удалось скачать обновление"
  fi
  [ -s "$2" ] || err "пустой ответ сервера автообновления"
  sz=$(wc -c < "$2" | tr -d ' ')
  [ "$sz" -le 1048576 ] || err "слишком большой ответ автообновления"
}
gen(){ # $1 linkfile $2 mode $3 proto
  P=${3:-$PROTO}
  L=$(cat "$1" | tr -d '\r\n ')
  case "$L" in vless://*) ;; *) err "Ссылка должна начинаться с vless://";; esac
  H=$(echo "$L" | sed -E 's#^vless://[^@]+@\[?([^]:/?#]+)\]?:.*#\1#')
  if echo "$H" | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then IP=$H
  else IP=$(nslookup "$H" 2>/dev/null | awk '/^Name:/{n=1} n&&/^Address/{print $NF}' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)
  fi
  [ -n "$IP" ] || err "Не удалось получить IP сервера $H"
  printf '%s\n' "$L" > /tmp/vless.link
  ucode $D/gen.uc /tmp/vless.link "$IP" "$2" > /tmp/vless.json 2>/tmp/vless.err || err "$(cat /tmp/vless.err)"
  if [ "$P" = hy2 ]; then
    [ -s $HYD/client.yaml ] || err "Сначала сохрани ссылку Hysteria2"
    jq '(.outbounds[] | select(.tag=="proxy")) |= {tag:"proxy",protocol:"socks",settings:{servers:[{address:"127.0.0.1",port:10818}]}}' /tmp/vless.json > /tmp/vless.j2 && mv /tmp/vless.j2 /tmp/vless.json || err "jq"
  fi
  if [ "$P" = naive ]; then
    [ -s $NAD/config.json ] || err "Сначала сохрани ссылку Naive"
    # Naive is TCP-only: DNS goes as DNS-over-TCP through the tunnel, QUIC is blocked (browsers fall back to TCP), other UDP goes direct
    jq '(.outbounds[] | select(.tag=="proxy")) |= {tag:"proxy",protocol:"socks",settings:{servers:[{address:"127.0.0.1",port:10828}]}}
      | .outbounds += [{tag:"dns-out",protocol:"dns",settings:{network:"tcp",address:"1.1.1.1",port:53}},{tag:"block",protocol:"blackhole"}]
      | .dns = {servers:["tcp://1.1.1.1","tcp://8.8.8.8"],queryStrategy:"UseIPv4"}
      | .routing.rules = [{type:"field",inboundTag:["dns-in"],outboundTag:"dns-out"},{type:"field",network:"udp",port:"53",outboundTag:"dns-out"},{type:"field",network:"udp",port:"443",outboundTag:"block"}] + .routing.rules[0:-1] + [{type:"field",network:"udp",outboundTag:"direct"}] + .routing.rules[-1:]' /tmp/vless.json > /tmp/vless.j2 && mv /tmp/vless.j2 /tmp/vless.json || err "jq"
  fi
  if [ "$P" = wg ]; then
    [ -s $D/wg.json ] || err "Сначала сохрани конфиг WireGuard"
    jq --slurpfile w $D/wg.json '(.outbounds[] | select(.tag=="proxy")) |= ($w[0] + {tag:"proxy",streamSettings:{sockopt:{mark:255}}})' /tmp/vless.json > /tmp/vless.j2 && mv /tmp/vless.j2 /tmp/vless.json || err "jq"
  fi
  XRAY_LOCATION_ASSET=/usr/share/xray xray run -test -c /tmp/vless.json >/tmp/vless.err 2>&1 || err "Xray отклонил конфиг: $(tail -3 /tmp/vless.err)"
  cp $D/config.json $D/config.prev.json 2>/dev/null
  mv /tmp/vless.json $D/config.json; mv /tmp/vless.link $D/link.txt; echo "$IP" > $D/server_ip; echo "$2" > $D/mode; echo "$P" > $D/proto
  hyup "$P"
  xrestart || { cp $D/config.prev.json $D/config.json; echo "$PROTO" > $D/proto; echo "$MODE" > $D/mode; hyup "$PROTO"; xrestart; au_tproxy; err "Xray не запустился, конфиг откатан"; }
  au_tproxy
  echo OK
}
store_vless(){
  L=$(cat "$1" | tr -d '\r\n ')
  case "$L" in vless://*) ;; *) err "Ссылка должна начинаться с vless://";; esac
  printf '%s\n' "$L" > $D/link.txt
}
store_hy2(){
  L=$(cat "$1" | tr -d '\r\n ')
  printf '%s\n' "$L" > /tmp/hy2.link
  ucode $D/hy2.uc /tmp/hy2.link > /tmp/hy2.yaml 2>/tmp/hy2.err || err "$(cat /tmp/hy2.err)"
  mkdir -p $HYD; cp $HYD/client.yaml $HYD/client.yaml.prev 2>/dev/null
  mv /tmp/hy2.yaml $HYD/client.yaml; mv /tmp/hy2.link $D/hy2.txt
}
store_naive(){
  L=$(cat "$1" | tr -d '\r\n ')
  case "$L" in naive+https://*@*) ;; *) err "Ссылка должна начинаться с naive+https://";; esac
  U=$(echo "$L" | sed -E 's#^naive\+https://([^@]+)@.*#\1#')
  HP=$(echo "$L" | sed -E 's#^naive\+https://[^@]+@([^/?\#]+).*#\1#')
  NH=${HP%:*}; NP=${HP##*:}; [ "$NP" = "$HP" ] && NP=443
  if echo "$NH" | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then NIP=$NH
  else NIP=$(nslookup "$NH" 2>/dev/null | awk '/^Name:/{n=1} n&&/^Address/{print $NF}' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1); [ -n "$NIP" ] || NIP=$(cat $D/server_ip); fi
  mkdir -p $NAD; cp $NAD/config.json $NAD/config.json.prev 2>/dev/null
  jq -n --arg p "https://$U@$NH:$NP" --arg r "MAP $NH $NIP" '{listen:"socks://127.0.0.1:10828",proxy:$p,"host-resolver-rules":$r}' > $NAD/config.json || err "jq"
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
      print "]}}" }' /tmp/wg.conf > /tmp/wg.json 2>/dev/null || { rm -f /tmp/wg.conf; err "Не похоже на конфиг WireGuard (нужны [Interface] PrivateKey и [Peer])"; }
  jq -e . /tmp/wg.json >/dev/null 2>&1 || { rm -f /tmp/wg.conf /tmp/wg.json; err "Ошибка разбора конфига WireGuard"; }
  umask 077; mv /tmp/wg.json $D/wg.json; mv /tmp/wg.conf $D/wg.conf
}
store_proto(){
  case "$1" in
    vless) store_vless "$2" ;;
    hy2) store_hy2 "$2" ;;
    naive) store_naive "$2" ;;
    wg) store_wg "$2" ;;
    *) err "store vless|hy2|naive|wg" ;;
  esac
}
do_update(){
  P=$1
  au_ok_proto "$P" || err "update vless|hy2|naive|wg"
  au_load "$P"
  URL=$(au_resolve_url "$P")
  if [ -z "$URL" ]; then
    echo "нечего обновлять: укажите ссылку автообновления под этим протоколом"
    return 0
  fi
  IN=/tmp/vless-au-$P.in
  OUT=/tmp/vless-au-$P.out
  au_fetch "$URL" "$IN"
  au_extract "$IN" "$P" "$OUT" || { rm -f "$IN"; err "в ответе нет конфига для $P"; }
  rm -f "$IN"
  CUR=$(au_current_file "$P")
  if [ -f "$CUR" ] && au_same "$P" "$CUR" "$OUT"; then
    rm -f "$OUT"
    echo "без изменений"
    return 0
  fi
  B=/tmp/vless-au-bak-$$
  au_backup "$B"
  if [ "$PROTO" = "$P" ]; then
    if [ "$P" = naive ] && [ ! -x /usr/bin/naive ] && [ -z "${VLESS_AU_APPLY:-}" ]; then
      rm -rf "$B" "$OUT"
      err "Сначала установи naive: /usr/libexec/vless-panel/install-naive.sh"
    fi
    if [ -n "${VLESS_AU_APPLY:-}" ]; then
      if ! sh "$VLESS_AU_APPLY" "$P" "$OUT"; then
        au_restore "$B"; hyup "$(cat $D/proto 2>/dev/null || echo vless)"; xrestart; au_tproxy
        rm -rf "$B" "$OUT"
        err "не удалось применить обновление, конфиг откатан"
      fi
    else
      # Child process: store/gen call err() and exit; the parent can still roll back.
      case "$P" in
        vless) cmd=save ;;
        hy2) cmd=hy2save ;;
        naive) cmd=naivesave ;;
        wg) cmd=wgsave ;;
      esac
      if ! "$0" "$cmd" "$OUT" >/tmp/vless-au-apply.out 2>&1; then
        au_restore "$B"; hyup "$(cat $D/proto 2>/dev/null || echo vless)"; xrestart; au_tproxy
        rm -rf "$B" "$OUT"
        err "не удалось применить обновление, конфиг откатан: $(cat /tmp/vless-au-apply.out 2>/dev/null)"
      fi
    fi
    if ! au_probe; then
      au_restore "$B"
      hyup "$(cat $D/proto 2>/dev/null || echo vless)"
      xrestart
      au_tproxy
      rm -rf "$B" "$OUT"
      err "после обновления нет интернета, конфиг откатан"
    fi
    au_tproxy
    rm -rf "$B" "$OUT"
    echo OK
  else
    if ! "$0" store "$P" "$OUT" >/tmp/vless-au-store.out 2>&1; then
      au_restore "$B"
      rm -rf "$B" "$OUT"
      err "не удалось сохранить обновление, файлы откатены: $(cat /tmp/vless-au-store.out 2>/dev/null)"
    fi
    rm -rf "$B" "$OUT"
    echo "Сохранено, без переключения (сейчас $PROTO)"
  fi
}
MODE=$(cat $D/mode 2>/dev/null || echo ru)
case "$1" in
save) store_vless "$2"; gen $D/link.txt "$MODE" vless;;
hy2save) store_hy2 "$2"; gen $D/link.txt "$MODE" hy2;;
naivesave)
  [ -x /usr/bin/naive ] || err "Сначала установи naive: /usr/libexec/vless-panel/install-naive.sh"
  store_naive "$2"; gen $D/link.txt "$MODE" naive;;
wgsave) store_wg "$2"; gen $D/link.txt "$MODE" wg;;
store) store_proto "$2" "$3"; echo OK;;
proto) case "$2" in vless|hy2|naive|wg) ;; *) err "proto vless|hy2|naive|wg";; esac; gen $D/link.txt "$MODE" "$2";;
mode) case "$2" in ru|all) ;; *) err "mode ru|all";; esac; gen $D/link.txt "$2";;
on) rm -f $D/tproxy.disabled; hyup "$PROTO"; /etc/init.d/xray-client enable; xrestart || err "Xray не запустился"; echo OK;;
off) touch $D/tproxy.disabled; $D/tproxy.sh down; echo OK;;
status)
  echo "running=$(pidof xray >/dev/null && echo 1 || echo 0)"
  echo "tproxy=$(nft list table inet xray >/dev/null 2>&1 && echo 1 || echo 0)"
  echo "mode=$MODE"; echo "proto=$PROTO"; echo "server_ip=$(cat $D/server_ip 2>/dev/null)";;
autoset)
  au_save_conf "$2" "$3" "$4" "$5" || err "autoset <proto> <0|1> <url> <1h|6h|24h>"
  echo OK;;
update) do_update "$2";;
*) err "usage";;
esac
