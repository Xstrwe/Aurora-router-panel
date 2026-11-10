#!/bin/sh
# TCP -> REDIRECT to :12346 ; UDP -> TPROXY to :12345
SIP=$(cat /etc/xray/server_ip 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
EXTRA=""; [ -n "$SIP" ] && EXTRA=", $SIP"
case "$1" in
up)
  ip rule show | grep -q "fwmark 0x1 lookup 100" || ip rule add fwmark 1 table 100
  ip route replace local 0.0.0.0/0 dev lo table 100
  nft delete table inet xray 2>/dev/null
  nft -f - <<NFT
table inet xray {
  set bypass4 { type ipv4_addr; flags interval; elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4$EXTRA } }
  chain nat_pre {
    type nat hook prerouting priority dstnat - 5; policy accept;
    iifname != "br-lan" return
    meta nfproto != ipv4 return
    ip daddr @bypass4 return
    meta l4proto tcp counter redirect to :12346
  }
  chain dns_out {
    type nat hook output priority -105; policy accept;
    meta mark 255 return
    meta nfproto != ipv4 return
    ip daddr @bypass4 return
    meta l4proto { tcp, udp } th dport 53 counter redirect to :5354
  }
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname != "br-lan" return
    meta nfproto != ipv4 return
    meta mark 255 return
    ip daddr @bypass4 return
    udp dport { 53, 67, 68, 123 } return
    meta l4proto udp counter meta mark set 1 tproxy ip to 127.0.0.1:12345 accept
  }
}
NFT
  ;;
down)
  nft delete table inet xray 2>/dev/null
  ip rule del fwmark 1 table 100 2>/dev/null
  ip route flush table 100 2>/dev/null
  ;;
esac
