# Changelog

## 1.3.0

- Removed the "our server" autoupdate source: the UI line and select, the
  `autoupdate-server` file, and the related code in the autoupdate library,
  CGI and `vless.sh`. Autoupdate now takes the fresh config from the
  protocol's own source: the link in the autoupdate field under each protocol
  block, or, if that field is empty, the protocol's saved connection link when
  it is an http(s) subscription URL. Otherwise there is nothing to update
  (`vless.sh update` prints "nothing to update" and exits 0). Old `source=`
  lines in `/etc/xray/autoupdate/*.conf` are ignored.
  `vless.sh autoset` now takes `<proto> <0|1> <url> <1h|6h|24h>`.
- `xrestart()` no longer races two xray instances: after stop it waits up to
  10 s for xray to exit and then runs `killall -9 xray`. It also waits until
  TCP 10808/12346 and UDP 12345 are free, and after start waits up to 15 s for
  10808 and 12346 to listen. The rollback path now restores proto, mode and
  the helper services and re-runs `tproxy.sh up` (unless `tproxy.disabled`
  exists).
- Web page: the VLESS card now has the same structure as the Hy2, Naive and
  WireGuard cards (link field, "Подключить VLESS" button, autoupdate block),
  and the protocol cards are laid out in a responsive grid, two columns on
  wide screens and one on narrow ones.
- `build.sh` verifies the ipk member order (`./debian-binary`,
  `./control.tar.gz`, `./data.tar.gz`). The feed under `feed/` is rebuilt by CI.

## 1.2.1

- Naive: DNS over TCP through the tunnel, QUIC blocked; opkg install steps and
  auth check.

## 1.2.0

- Per-protocol config autoupdate.
