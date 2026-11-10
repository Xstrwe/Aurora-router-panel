#!/bin/sh
# vless.sh save <linkfile> | hy2save <linkfile> | proto vless|hy2 | mode ru|all | on | off | status
D=/etc/xray
err(){ echo "ERROR: $*"; exit 1; }
PROTO=$(cat $D/proto 2>/dev/null || echo vless)
hyup(){ if [ "$1" = hy2 ]; then /etc/init.d/hysteria-client enable; /etc/init.d/hysteria-client restart; else /etc/init.d/hysteria-client stop >/dev/null 2>&1; /etc/init.d/hysteria-client disable >/dev/null 2>&1; fi; }
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
    [ -s /etc/hysteria/client.yaml ] || err "Сначала сохрани ссылку Hysteria2"
    jq '(.outbounds[] | select(.tag=="proxy")) |= {tag:"proxy",protocol:"socks",settings:{servers:[{address:"127.0.0.1",port:10818}]}}' /tmp/vless.json > /tmp/vless.j2 && mv /tmp/vless.j2 /tmp/vless.json || err "jq"
  fi
  XRAY_LOCATION_ASSET=/usr/share/xray xray run -test -c /tmp/vless.json >/tmp/vless.err 2>&1 || err "Xray отклонил конфиг: $(tail -3 /tmp/vless.err)"
  cp $D/config.json $D/config.prev.json 2>/dev/null
  mv /tmp/vless.json $D/config.json; mv /tmp/vless.link $D/link.txt; echo "$IP" > $D/server_ip; echo "$2" > $D/mode; echo "$P" > $D/proto
  hyup "$P"
  /etc/init.d/xray-client restart; sleep 2
  pidof xray >/dev/null || { cp $D/config.prev.json $D/config.json; /etc/init.d/xray-client restart; err "Xray не запустился, конфиг откатан"; }
  echo OK
}
MODE=$(cat $D/mode 2>/dev/null || echo ru)
case "$1" in
save) gen "$2" "$MODE" vless;;
hy2save)
  L=$(cat "$2" | tr -d '\r\n ')
  printf '%s\n' "$L" > /tmp/hy2.link
  ucode $D/hy2.uc /tmp/hy2.link > /tmp/hy2.yaml 2>/tmp/hy2.err || err "$(cat /tmp/hy2.err)"
  mkdir -p /etc/hysteria; cp /etc/hysteria/client.yaml /etc/hysteria/client.yaml.prev 2>/dev/null
  mv /tmp/hy2.yaml /etc/hysteria/client.yaml; mv /tmp/hy2.link $D/hy2.txt
  gen $D/link.txt "$MODE" hy2;;
proto) case "$2" in vless|hy2) ;; *) err "proto vless|hy2";; esac; gen $D/link.txt "$MODE" "$2";;
mode) case "$2" in ru|all) ;; *) err "mode ru|all";; esac; gen $D/link.txt "$2";;
on) rm -f $D/tproxy.disabled; hyup "$PROTO"; /etc/init.d/xray-client enable; /etc/init.d/xray-client restart; echo OK;;
off) touch $D/tproxy.disabled; $D/tproxy.sh down; echo OK;;
status)
  echo "running=$(pidof xray >/dev/null && echo 1 || echo 0)"
  echo "tproxy=$(nft list table inet xray >/dev/null 2>&1 && echo 1 || echo 0)"
  echo "mode=$MODE"; echo "proto=$PROTO"; echo "server_ip=$(cat $D/server_ip 2>/dev/null)";;
*) err "usage";;
esac
