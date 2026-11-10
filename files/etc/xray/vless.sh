#!/bin/sh
# vless.sh save <linkfile> | hy2save <linkfile> | naivesave <linkfile> | wgsave <conffile> | proto vless|hy2|naive|wg | mode ru|all | on | off | status
D=/etc/xray
err(){ echo "ERROR: $*"; exit 1; }
PROTO=$(cat $D/proto 2>/dev/null || echo vless)
svc(){ if [ "$2" = 1 ]; then /etc/init.d/$1 enable; /etc/init.d/$1 restart; else /etc/init.d/$1 stop 2>/dev/null; /etc/init.d/$1 disable 2>/dev/null; fi; }
hyup(){ [ "$1" = hy2 ] && svc hysteria-client 1 || svc hysteria-client 0; [ "$1" = naive ] && svc naive-client 1 || svc naive-client 0; }
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
  if [ "$P" = naive ]; then
    [ -s /etc/naive/config.json ] || err "Сначала сохрани ссылку Naive"
    jq '(.outbounds[] | select(.tag=="proxy")) |= {tag:"proxy",protocol:"socks",settings:{servers:[{address:"127.0.0.1",port:10828}]}}' /tmp/vless.json > /tmp/vless.j2 && mv /tmp/vless.j2 /tmp/vless.json || err "jq"
  fi
  if [ "$P" = wg ]; then
    [ -s $D/wg.json ] || err "Сначала сохрани конфиг WireGuard"
    jq --slurpfile w $D/wg.json '(.outbounds[] | select(.tag=="proxy")) |= ($w[0] + {tag:"proxy",streamSettings:{sockopt:{mark:255}}})' /tmp/vless.json > /tmp/vless.j2 && mv /tmp/vless.j2 /tmp/vless.json || err "jq"
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
naivesave)
  L=$(cat "$2" | tr -d '\r\n ')
  case "$L" in naive+https://*@*) ;; *) err "Ссылка должна начинаться с naive+https://";; esac
  [ -x /usr/bin/naive ] || err "Сначала установи naive: /usr/libexec/vless-panel/install-naive.sh"
  U=$(echo "$L" | sed -E 's#^naive\+https://([^@]+)@.*#\1#')
  HP=$(echo "$L" | sed -E 's#^naive\+https://[^@]+@([^/?\#]+).*#\1#')
  NH=${HP%:*}; NP=${HP##*:}; [ "$NP" = "$HP" ] && NP=443
  if echo "$NH" | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then NIP=$NH
  else NIP=$(nslookup "$NH" 2>/dev/null | awk '/^Name:/{n=1} n&&/^Address/{print $NF}' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1); [ -n "$NIP" ] || NIP=$(cat $D/server_ip); fi
  mkdir -p /etc/naive; cp /etc/naive/config.json /etc/naive/config.json.prev 2>/dev/null
  jq -n --arg p "https://$U@$NH:$NP" --arg r "MAP $NH $NIP" '{listen:"socks://127.0.0.1:10828",proxy:$p,"host-resolver-rules":$r}' > /etc/naive/config.json || err "jq"
  chmod 600 /etc/naive/config.json; printf '%s\n' "$L" > $D/naive.txt; chmod 600 $D/naive.txt
  gen $D/link.txt "$MODE" naive;;
wgsave)
  tr -d '\r' < "$2" > /tmp/wg.conf
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
  gen $D/link.txt "$MODE" wg;;
proto) case "$2" in vless|hy2|naive|wg) ;; *) err "proto vless|hy2|naive|wg";; esac; gen $D/link.txt "$MODE" "$2";;
mode) case "$2" in ru|all) ;; *) err "mode ru|all";; esac; gen $D/link.txt "$2";;
on) rm -f $D/tproxy.disabled; hyup "$PROTO"; /etc/init.d/xray-client enable; /etc/init.d/xray-client restart; echo OK;;
off) touch $D/tproxy.disabled; $D/tproxy.sh down; echo OK;;
status)
  echo "running=$(pidof xray >/dev/null && echo 1 || echo 0)"
  echo "tproxy=$(nft list table inet xray >/dev/null 2>&1 && echo 1 || echo 0)"
  echo "mode=$MODE"; echo "proto=$PROTO"; echo "server_ip=$(cat $D/server_ip 2>/dev/null)";;
*) err "usage";;
esac
