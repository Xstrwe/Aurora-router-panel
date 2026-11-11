// usage: ucode gen.uc <linkfile> <server_ip> <mode ru|all>  -> prints a vless config
//        ucode gen.uc --base <mode ru|all>                  -> inbounds, routing, placeholder proxy
import * as fs from 'fs';
function die(m) { warn(m + "\n"); exit(1); }
function dec(s) {
	s = replace(s, /\+/g, ' ');
	return replace(s, /%([0-9A-Fa-f]{2})/g, (m, h) => chr(hex(h)));
}
function rules_for(mode) {
	let rules = [ { type: 'field', inboundTag: [ 'dns-in' ], outboundTag: 'proxy' }, { type: 'field', ip: [ 'geoip:private' ], outboundTag: 'direct' } ];
	if (mode != 'all') {
		push(rules, { type: 'field', domain: [ 'geosite:category-ru', 'regexp:\\.(ru|su|xn--p1ai|xn--d1acj3b|moscow|tatar)$' ], outboundTag: 'direct' });
		push(rules, { type: 'field', ip: [ 'geoip:ru' ], outboundTag: 'direct' });
	}
	push(rules, { type: 'field', network: 'tcp,udp', outboundTag: 'proxy' });
	return rules;
}
function inbounds() {
	let sniff = { enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: true };
	return [
		{ tag: 'tproxy', listen: '127.0.0.1', port: 12345, protocol: 'dokodemo-door', settings: { network: 'udp', followRedirect: true }, streamSettings: { sockopt: { tproxy: 'tproxy' } }, sniffing: sniff },
		{ tag: 'redir', listen: '0.0.0.0', port: 12346, protocol: 'dokodemo-door', settings: { network: 'tcp', followRedirect: true }, streamSettings: { sockopt: { tproxy: 'redirect' } }, sniffing: sniff },
		{ tag: 'dns-in', listen: '127.0.0.1', port: 5354, protocol: 'dokodemo-door', settings: { address: '1.1.1.1', port: 53, network: 'tcp,udp' } },
		{ tag: 'socks', listen: '0.0.0.0', port: 10808, protocol: 'socks', settings: { udp: true }, sniffing: sniff },
		{ tag: 'http', listen: '0.0.0.0', port: 10809, protocol: 'http' }
	];
}
function base_cfg(mode, proxy) {
	return {
		log: { loglevel: 'warning' },
		inbounds: inbounds(),
		outbounds: [
			proxy,
			{ tag: 'direct', protocol: 'freedom', streamSettings: { sockopt: { mark: 255 } } }
		],
		routing: { domainStrategy: 'IPIfNonMatch', rules: rules_for(mode) }
	};
}

if (ARGV[0] == '--base') {
	let mode = ARGV[1] || 'ru';
	let proxy = { tag: 'proxy', protocol: 'freedom', streamSettings: { sockopt: { mark: 255 } } };
	print(sprintf("%.2J\n", base_cfg(mode, proxy)));
	exit(0);
}

let link = trim(fs.readfile(ARGV[0]) || '');
let sip = ARGV[1], mode = ARGV[2] || 'ru';
let m = match(link, /^vless:\/\/([^@]+)@(\[[^\]]+\]|[^:\/?#]+):([0-9]+)\/?(\?[^#]*)?(#.*)?$/);
if (!m) die("Ссылка не похожа на vless://uuid@host:port?...");
let uuid = dec(m[1]), port = +m[3];
if (!match(uuid, /^[0-9a-fA-F-]{8,}$/)) die("Неверный UUID");
let q = {};
for (let kv in split(substr(m[4] || '?', 1), '&')) {
	if (kv == '') continue;
	let i = index(kv, '=');
	if (i < 0) q[dec(kv)] = ''; else q[dec(substr(kv, 0, i))] = dec(substr(kv, i + 1));
}
let type = q.type || 'tcp', sec = q.security || 'none';
let user = { id: uuid, encryption: q.encryption || 'none' };
if (q.flow) user.flow = q.flow;
let ss = { network: type, security: sec, sockopt: { mark: 255 } };
if (type == 'xhttp' || type == 'splithttp') {
	ss.network = 'xhttp';
	let x = { path: q.path || '/', mode: q.mode || 'auto' };
	if (q.host) x.host = q.host;
	let extra = {};
	if (q.extra) { try { extra = json(q.extra); } catch (e) { die("Поле extra не является JSON"); } }
	if (q.x_padding_bytes && !extra.xPaddingBytes) extra.xPaddingBytes = q.x_padding_bytes;
	if (length(extra)) x.extra = extra;
	ss.xhttpSettings = x;
} else if (type == 'ws') {
	ss.wsSettings = { path: q.path || '/' };
	if (q.host) ss.wsSettings.host = q.host;
} else if (type == 'grpc') {
	ss.grpcSettings = { serviceName: q.serviceName || q.path || '' };
	if (q.mode == 'multi') ss.grpcSettings.multiMode = true;
} else if (type == 'httpupgrade') {
	ss.httpupgradeSettings = { path: q.path || '/' };
	if (q.host) ss.httpupgradeSettings.host = q.host;
} else if (type == 'tcp' || type == 'raw') {
	ss.network = 'raw';
	if (q.headerType == 'http') ss.rawSettings = { header: { type: 'http', request: { path: [ q.path || '/' ], headers: { Host: [ q.host || '' ] } } } };
} else die("Неподдерживаемый type=" + type);
if (sec == 'reality') {
	if (!q.pbk) die("Для reality нужен pbk");
	ss.realitySettings = { serverName: q.sni || '', fingerprint: q.fp || 'chrome', publicKey: q.pbk, shortId: q.sid || '', spiderX: q.spx || '' };
} else if (sec == 'tls') {
	ss.tlsSettings = { serverName: q.sni || q.host || '', fingerprint: q.fp || 'chrome' };
	if (q.alpn) ss.tlsSettings.alpn = split(q.alpn, ',');
	if (q.allowInsecure == '1') ss.tlsSettings.allowInsecure = true;
} else if (sec != 'none') die("Неподдерживаемый security=" + sec);
let proxy = { tag: 'proxy', protocol: 'vless', settings: { vnext: [ { address: sip, port: port, users: [ user ] } ] }, streamSettings: ss };
print(sprintf("%.2J\n", base_cfg(mode, proxy)));
