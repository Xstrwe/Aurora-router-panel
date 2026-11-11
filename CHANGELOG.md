# Changelog

## 1.3.0a4

- **Прокси** section: SOCKS5 and HTTP are no longer static address cards.
  Each one starts with an **Добавить** button; pressing it reveals separate
  fields (address, port, login, password). The HTTP card also has a TLS
  toggle, SNI, and "не проверять сертификат". **Подключить SOCKS5** /
  **Подключить HTTP** saves the fields and switches the tunnel to that
  upstream. There is no link field, no auto-update row and no "Обновить
  сейчас" — these protocols have no subscription to pull from.
- New backend protos `socks` and `http` (`vless.sh sockssave` / `httpsave`,
  `store`, `proto`). Settings are stored in `/etc/xray/socks.json` and
  `/etc/xray/http.json` (mode 600). The generated xray config keeps the
  usual inbounds (SOCKS 10808, HTTP 10809, tproxy 12345/12346, DNS 5354)
  and RU-direct routing; the `proxy` outbound is an xray socks or http
  outbound to the given upstream (the upstream IPv4 is added to the
  tproxy bypass set). An HTTP upstream cannot carry UDP: DNS goes over
  TCP through the tunnel, QUIC is blocked, other UDP goes direct. The
  local LAN addresses stay as a hint under the section.
- `ucode gen.uc --base <mode>` builds a skeleton config without a
  vless:// link, so a SOCKS/HTTP upstream can be used on its own.
  `vless.sh mergecfg` is used to assemble the outbound (and is covered
  by tests).


## 1.3.0a3

- Web page: the four protocol cards sit in a **VPN** section (heading at
  the top). The two-column layout is a CSS grid, so both columns start on
  the same line (the previous multi-column layout left a gap above the
  right column). Cards still size to their content: VLESS and Hysteria2
  on the left, Naive and WireGuard on the right (one column on a narrow
  screen).
- A **Прокси** section below it has two cards in the same grid: SOCKS5
  (`192.168.8.1:10808`) and HTTP (`192.168.8.1:10809`), each with a short
  note that the address is for configuring individual apps by hand. Proxy
  behaviour is unchanged.
- The old footer line about proxies is removed. A small "IPv6 не
  проксируется." note stays at the bottom of the VPN section.


## 1.3.0a2

- Web page: the vless / hysteria2 / naive link fields and the WireGuard
  `.conf` field grow with their content (no fixed height, no inner
  scroll) on input, paste and page load. Long links wrap inside the field.
- If a protocol has no saved link or config, the field is hidden and an
  **Добавить** button is shown instead; pressing it reveals the field and
  focuses it. The rest of the card (auto-update row and the Connect /
  Update now buttons) is unchanged.


## 1.3.0a1

- Web page, all four protocol cards: the "Автообновление" row now holds the
  checkbox and the interval on one line. The separate update-URL field and its
  hint are removed, and so is every "Сохранить" button. "Обновить сейчас" sits
  next to "Подключить …" in each card; it saves the auto-update settings and
  the link, then runs the update. "Подключить …" now saves the auto-update
  settings too.
- Cards size to their content and stack in two CSS columns, so a short card no
  longer leaves a gap.
- Auto-update has a single source: the protocol's own saved connection link.
  An `http(s)` subscription URL entered in a card's link field is kept in
  `/etc/xray/autoupdate/<proto>.src` and the first matching link or config
  from it is applied; any other link has nothing to re-fetch. New command
  `vless.sh src <proto> <infile> <outfile> <0|1>`; `vless.sh autoset` is now
  `<proto> <0|1> <1h|6h|24h>`. Existing `url=` lines in
  `/etc/xray/autoupdate/*.conf` are ignored, so a URL that was only typed into
  the old field must be pasted into the link field again.
- Tests cover the new source handling and the page layout.
- Versioning: versions `X.Y.Z<letter><digits>` (such as this `1.3.0a1`) are
  published as GitHub pre-releases (`vX.Y.Za1` with `.ipk` and `.sha256`); round
  `X.Y.0` stays a full Release. The signed Pages feed now keeps every published
  `.ipk` and its `Packages` lists the newest version (opkg ordering:
  `1.3.0 < 1.3.0a1 < 1.3.0a2 < 1.3.0a10 < 1.3.0b1 < 1.4.0`). New
  `tools/vercmp.sh` (port of opkg's `verrevcmp`), `tools/mkfeed.sh` and
  `tests/version-order.sh`, which runs in CI through `build.sh`. See the
  README section "Versioning".

## 1.3.0

- Renamed the project to Aurora-router-panel: package `aurora-router-panel`
  (declares `Replaces`/`Conflicts: vless-router-panel`), page title, README,
  feed URLs and the GitHub repository (Xstrwe/Aurora-router-panel; the old URL
  redirects). Files moved to `/usr/libexec/aurora-panel` and `/www-aurora`, the
  uhttpd section is now `uhttpd.aurora` (same listen address), and the
  autoupdate cron line is rewritten for the new path (the legacy line is
  removed). `/etc/xray/vless.sh`, `/cgi-bin/vless` and all user state under
  `/etc/xray`, `/etc/hysteria` and `/etc/naive` are unchanged. opkg drops
  files shared by both packages from the new file list when it removes the old
  package, so `postinst` re-adds them (generated by `build.sh`).

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
- Release automation: a round `X.Y.0` version creates the tag and a GitHub
  Release (`.ipk` and `.sha256` attached) and publishes a usign-signed opkg
  feed on GitHub Pages (`https://xstrwe.github.io/Aurora-router-panel/all`).
  No change to the package contents.

## 1.2.1

- Naive: DNS over TCP through the tunnel, QUIC blocked; opkg install steps and
  auth check.

## 1.2.0

- Per-protocol config autoupdate.
