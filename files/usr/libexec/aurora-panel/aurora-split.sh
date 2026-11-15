#!/bin/sh
# aurora-split.sh <hy|nv|wg> up|down|render|conf
#
# Traffic steering for the protocols that have no routing of their own. Every
# protocol owns its table and its split config; nothing is shared at run time:
#   hy  Hysteria  table inet aurora_hy  /etc/hysteria/split.conf  tcpRedirect :12356, udpTProxy :12355, DNS forwarder :536454
#   nv  Naive     table inet aurora_nv  /etc/naive/split.conf     redir :12366, DNS (dnsproxy over TCP) :5374
#   wg  WireGuard table inet aurora_wg  /etc/xray/wg.split.conf   fwmark -> table 871 -> wg-aurora, masquerade
# (VLESS keeps its own tproxy table and Xray routing rules.)
#
# split.conf lines (anything after # is a comment):
#   mode ru|all          ru: the "direct" lines apply; all: only private ranges and explicit CIDRs go direct
#   direct private       always implied (loopback, LAN, multicast): they never go through a tunnel
#   direct geoip:ru      country ranges from geoip.dat (ignored in mode all)
#   direct 203.0.113.0/24   an address or CIDR that always goes direct
set -u
P=${1:-}
ACT=${2:-}
NFT=${AURORA_NFT:-nft}
IPC=${AURORA_IP:-ip}
GEO=${AURORA_GEOIP_SH:-$(dirname "$0")/aurora-geoip.sh}
LAN=${AURORA_LAN_IF:-br-lan}
WGIF=wg-aurora

case "$P" in
	hy) NAME=Hysteria; TABLE=aurora_hy; CONF=${AURORA_HY_SPLIT:-/etc/hysteria/split.conf}; SIPF=${AURORA_HY_SERVER_IP:-/etc/hysteria/server_ip};;
	nv) NAME=Naive; TABLE=aurora_nv; CONF=${AURORA_NV_SPLIT:-/etc/naive/split.conf}; SIPF=${AURORA_NV_SERVER_IP:-/etc/naive/server_ip};;
	wg) NAME=WireGuard; TABLE=aurora_wg; CONF=${AURORA_WG_SPLIT:-/etc/xray/wg.split.conf}; SIPF=${AURORA_WG_SERVER_IP:-/etc/xray/wg.server_ip};;
	*) echo "usage: aurora-split.sh hy|nv|wg up|down|render|conf" >&2; exit 2;;
esac

PRIVATE="0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4"

ensure_conf() {
	[ -f "$CONF" ] && return 0
	mkdir -p "$(dirname "$CONF")"
	cat > "$CONF" <<CFG
# Aurora split rules for $NAME. Edit freely; applied when the service starts
# (or after: /usr/libexec/aurora-panel/aurora-split.sh $P up).
# mode ru  : the "direct" lines below bypass the tunnel
# mode all : only private ranges and explicit CIDR lines bypass the tunnel
mode ru
direct private
direct geoip:ru
CFG
}

# Print the set elements (comma separated) for the current config.
elements() {
	mode=ru; list=""
	while read -r kw arg rest; do
		case "$kw" in
			mode) [ "$arg" = all ] && mode=all || mode=ru;;
			direct) list="$list $arg";;
		esac
	done <<CFG
$(sed 's/#.*//' "$CONF")
CFG
	out="$PRIVATE"
	sip=$(grep -E '^[0-9]+(\.[0-9]+){3}$' "$SIPF" 2>/dev/null | head -1)
	[ -n "$sip" ] && out="$out, $sip"
	for a in $list; do
		case "$a" in
			private) ;;
			geoip:*) [ "$mode" = ru ] || continue
				cc=${a#geoip:}
				cidrs=$(sh "$GEO" "$cc" 2>/dev/null | tr '\n' ',' | sed 's/,$//; s/,/, /g')
				[ -n "$cidrs" ] && out="$out, $cidrs";;
			*[!0-9./]*|"") ;;
			*) out="$out, $a";;
		esac
	done
	printf '%s' "$out"
}

render() {
	el=$(elements)
	sip=$(grep -E '^[0-9]+(\.[0-9]+){3}$' "$SIPF" 2>/dev/null | head -1)
	cat <<NFTSET
table inet $TABLE {
  set direct4 { type ipv4_addr; flags interval; auto-merge; elements = { $el } }
NFTSET
	case "$P" in
	hy) cat <<NFT
  chain nat_pre {
    type nat hook prerouting priority dstnat - 4; policy accept;
    iifname != "$LAN" return
    meta nfproto != ipv4 return
    ip daddr @direct4 return
    meta l4proto tcp counter redirect to :12356
  }
  chain dns_out {
    type nat hook output priority -104; policy accept;
    meta nfproto != ipv4 return
    ip daddr @direct4 return
    meta l4proto { tcp, udp } th dport 53 counter redirect to :5364
  }
  chain tp_pre {
    type filter hook prerouting priority mangle; policy accept;
    iifname != "$LAN" return
    meta nfproto != ipv4 return
    ip daddr @direct4 return
    udp dport { 53, 67, 68, 123 } return
    meta l4proto udp counter meta mark set 0x11 tproxy ip to 127.0.0.1:12355 accept
  }
}
NFT
	;;
	nv) dns=0; { [ -n "${AURORA_DNSPROXY_UP:-}" ] || pidof dnsproxy >/dev/null 2>&1; } && dns=1
	cat <<NFT
  chain nat_pre {
    type nat hook prerouting priority dstnat - 4; policy accept;
    iifname != "$LAN" return
    meta nfproto != ipv4 return
    ip daddr @direct4 return
    meta l4proto tcp counter redirect to :12366
  }
  chain nat_out {
    type nat hook output priority -104; policy accept;
    meta nfproto != ipv4 return
NFT
	if [ "$dns" = 1 ]; then cat <<NFT
    meta skuid 65534 ip daddr 1.1.1.1 tcp dport 53 counter redirect to :12366
    meta skuid 65534 return
    ip daddr @direct4 return
    meta l4proto { tcp, udp } th dport 53 counter redirect to :5374
NFT
	fi
	cat <<NFT
  }
  chain quic_block {
    type filter hook prerouting priority mangle; policy accept;
    iifname != "$LAN" return
    meta nfproto != ipv4 return
    ip daddr @direct4 return
    udp dport 443 counter drop
  }
}
NFT
	;;
	wg) cat <<NFT
  chain mark_pre {
    type filter hook prerouting priority mangle; policy accept;
    iifname != "$LAN" return
    meta nfproto != ipv4 return
    ip daddr @direct4 return
    counter meta mark set meta mark & 0x00ffffff | 0x5a000000
  }
  chain dns_out {
    type route hook output priority mangle; policy accept;
    meta nfproto != ipv4 return
    ip daddr @direct4 return
    meta l4proto { tcp, udp } th dport 53 counter meta mark set meta mark & 0x00ffffff | 0x5a000000
  }
  chain mss {
    type filter hook forward priority mangle; policy accept;
    oifname "$WGIF" tcp flags syn tcp option maxseg size set rt mtu
  }
  chain masq {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$WGIF" counter masquerade
  }
}
NFT
	;;
	esac
}

fw4_forward() { # add|del the lan -> wg-aurora accept rule in fw4's forward chain
	$NFT list chain inet fw4 forward >/dev/null 2>&1 || return 0
	for h in $($NFT -a list chain inet fw4 forward 2>/dev/null | sed -n 's/.*aurora-wg.*# handle \([0-9]*\)$/\1/p'); do
		$NFT delete rule inet fw4 forward handle "$h" 2>/dev/null
	done
	[ "$1" = add ] && $NFT insert rule inet fw4 forward iifname "$LAN" oifname "$WGIF" accept comment "aurora-wg"
	return 0
}

up() {
	ensure_conf
	if [ "$P" = nv ] && command -v dnsproxy >/dev/null 2>&1 && [ -z "${AURORA_DNSPROXY_UP:-}" ]; then
		# Naive's DNS helper (dnsproxy, started by naive-client) must be listening before DNS is redirected to it.
		_n=0; while [ $_n -lt 10 ] && ! pidof dnsproxy >/dev/null 2>&1; do sleep 1; _n=$((_n+1)); done
	fi
	rm -f /tmp/aurora-split-$P.nft
	render > /tmp/aurora-split-$P.nft || return 1
	$NFT delete table inet "$TABLE" 2>/dev/null
	$NFT -f /tmp/aurora-split-$P.nft || { echo "nft rejected the $NAME split rules (see /tmp/aurora-split-$P.nft)" >&2; return 1; }
	case "$P" in
		hy)
			$IPC rule show | grep -q 'fwmark 0x11 lookup 111' || $IPC rule add fwmark 0x11 lookup 111 pref 111
			$IPC route replace local 0.0.0.0/0 dev lo table 111;;
		wg)
			$IPC rule del fwmark 0x5a000000/0xff000000 lookup 871 2>/dev/null
			$IPC rule add fwmark 0x5a000000/0xff000000 lookup 871 pref 872
			fw4_forward add;;
	esac
	return 0
}

down() {
	$NFT delete table inet "$TABLE" 2>/dev/null
	case "$P" in
		hy) $IPC rule del fwmark 0x11 lookup 111 2>/dev/null; $IPC route flush table 111 2>/dev/null;;
		wg) $IPC rule del fwmark 0x5a000000/0xff000000 lookup 871 2>/dev/null; fw4_forward del;;
	esac
	return 0
}

case "$ACT" in
	up) up;;
	down) down;;
	render) ensure_conf; render;;
	conf) ensure_conf; echo "$CONF";;
	*) echo "usage: aurora-split.sh hy|nv|wg up|down|render|conf" >&2; exit 2;;
esac
