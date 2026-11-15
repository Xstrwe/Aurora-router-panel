// usage: ucode hy2.uc <linkfile> -> prints hysteria client yaml
import * as fs from 'fs';
function die(m) { warn(m + "\n"); exit(1); }
function dec(s) { s = replace(s, /\+/g, ' '); return replace(s, /%([0-9A-Fa-f]{2})/g, (m, h) => chr(hex(h))); }
let link = trim(fs.readfile(ARGV[0]) || '');
let m = match(link, /^(hysteria2|hy2):\/\/([^@]+)@(\[[^\]]+\]|[^:\/?#]+):([0-9,\-]+)\/?(\?[^#]*)?(#.*)?$/);
if (!m) die("The link does not look like hysteria2://password@host:port?...");
let q = {};
for (let kv in split(substr(m[5] || '?', 1), '&')) {
	if (kv == '') continue;
	let i = index(kv, '=');
	if (i < 0) q[dec(kv)] = ''; else q[dec(substr(kv, 0, i))] = dec(substr(kv, i + 1));
}
let ports = m[4]; if (q.mport) ports = ports + ',' + q.mport;
let y = sprintf("server: %J\nauth: %J\ntls:\n  sni: %J\n  insecure: %s\n", m[3] + ':' + ports, dec(m[2]), q.sni || q.peer || '', (q.insecure == '1') ? 'true' : 'false');
if (q.pinSHA256) y += sprintf("  pinSHA256: %J\n", q.pinSHA256);
if (q.obfs && q.obfs != 'none') y += sprintf("obfs:\n  type: %J\n  %s:\n    password: %J\n", q.obfs, q.obfs, q['obfs-password'] || '');
// Own listeners: a local SOCKS5, the transparent TCP redirect and UDP TProxy that
// aurora-split.sh steers the LAN into, and a DNS forwarder (DNS goes through the tunnel).
y += "socks5:\n  listen: 127.0.0.1:10818\n";
y += "tcpRedirect:\n  listen: :12356\n";
y += "udpTProxy:\n  listen: :12355\n  timeout: 20s\n";
y += "tcpForwarding:\n  - listen: 127.0.0.1:5364\n    remote: 1.1.1.1:53\n";
y += "udpForwarding:\n  - listen: 127.0.0.1:5364\n    remote: 1.1.1.1:53\n    timeout: 10s\n";
print(y);
