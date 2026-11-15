# Changelog

## 1.4.0

Round release after 1.3.0a4: a reworked status card, equal-size VPN cards,
proxy cards behind buttons, a sturdier restart, and a private test mirror.

### Status card

- **Режим** (the routing mode selector) is the first row of the status card,
  above «Прозрачный режим для сети». The separate mode card is gone; the
  selector works as before.
- **Служба (демон)** (was «Служба Xray») lists every service behind the VPN
  cards in one row, separated by ` / `: **Xray** (`xray-client`), **Naive**
  (`naive-client`, the router's naive client), **Hysteria** (`hysteria-client`)
  and **WireGuard**. A running service is green; a stopped or missing one is
  red and bold, and the tooltip says "работает", "не запущен" or
  "не установлен". WireGuard has no process of its own, it is an outbound
  inside Xray: it is green when Xray runs and WireGuard is the connected
  protocol, and its button restarts Xray.
- Each service has its own small square **↻** restart button, 1.2 em (about
  the line height of the label), centred on the capital letters, with a small
  gap before the `/`. The old single big restart button is gone.
- A button restarts only that service: `vless.sh restart-svc
  xray|naive|hysteria|wireguard`, with a fixed whitelist of names (POST only,
  nothing typed reaches the shell). It never changes the active protocol, and
  restarting a service that is not the active protocol does not enable it at
  boot.
- If a restart fails, a banner at the very top of the page shows the reason in
  red uppercase and a concrete fix in green uppercase (config test failure,
  missing binary or config, busy port, permissions, daemon died, transparent
  mode down).
- **Протокол** shows the protocol last applied by a Connect button (VLESS,
  Hysteria2, Naive, WireGuard, SOCKS5 or HTTP).
- **IP выхода** (was «IP выхода через VLESS») is the final egress address: an
  echo request through the live tunnel (Xray SOCKS `10808`, the entry of the
  chain), so it is correct through several hops and is never the first server
  address saved in the config. It is fetched after the page has loaded
  (`GET ?ip`, one probe with a 3 s limit, cached for 60 s and dropped on
  restart), so a dead tunnel shows "не удалось определить" instead of hanging
  the page or the restart response.

### VPN and proxy cards

- The VPN cards are one equal-size grid. Every link field, including the
  WireGuard config, is a field of exactly two visible lines; longer text
  scrolls inside it. The WireGuard card has no «Добавить» button, only the
  same two-line field.
- **Добавить SOCKS5** and **Добавить HTTP** reveal the proxy cards; a proxy
  that is already saved is shown expanded. The footer notes stay.
- A failed SOCKS5 / HTTP save keeps the card open with the typed values.
- Fix: on the HTTP card, SNI and «не проверять сертификат» are shown only while
  TLS is checked (an inline `display:contents` had overridden `hidden`).

### Restart robustness

- Each daemon must still be the same process 3 s after start. After an Xray
  restart the transparent mode (`nft` table `inet xray`) must be up unless it
  was switched off.
- The CLI `vless.sh restart` (active protocol) restarts Hysteria or Naive
  before Xray, because the Xray outbound points at them.
- Removed a dead "address already in use" branch and unused variables in the
  page script.

### Repository

- The release workflow only runs in `Xstrwe/Aurora-router-panel`
  (`github.repository` guard), so the private `Xstrwe/Aurora-router-panel-dev`
  mirror, where updates are tested first, never tries to publish.

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
