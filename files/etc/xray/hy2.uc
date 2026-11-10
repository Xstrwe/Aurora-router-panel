// usage: ucode hy2.uc <linkfile> -> prints hysteria client yaml
import * as fs from 'fs';
function die(m) { warn(m + "\n"); exit(1); }
function dec(s) { s = replace(s, /\+/g, ' '); return replace(s, /%([0-9A-Fa-f]{2})/g, (m, h) => chr(hex(h))); }
let link = trim(fs.readfile(ARGV[0]) || '');
let m = match(link, /^(hysteria2|hy2):\/\/([^@]+)@(\[[^\]]+\]|[^:\/?#]+):([0-9,\-]+)\/?(\?[^#]*)?(#.*)?$/);
if (!m) die("Ссылка не похожа на hysteria2://пароль@адрес:порт?...");
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
y += "socks5:\n  listen: 127.0.0.1:10818\n";
print(y);
