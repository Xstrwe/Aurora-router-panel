# Changelog

## 1.5.0a5

Install the VPN clients from the panel. Pre-release.

- New **Install VPN clients** block in the middle of the page with four buttons:
  **Install VLESS**, **Install Hysteria 2**, **Install Naive** and
  **Install WireGuard**. Under each button a progress bar shows 0-100% and the current
  step. The block lists only the clients that are not installed yet (Naive counts as
  installed only when both `naive` and `dnsproxy` are present). While an install runs its
  card stays with the progress; at 100% it shows "Installed" for a moment and disappears.
  On an error the card stays with the reason. When all four clients are installed the whole
  block (heading, cards and hint) is not on the page.
- Every client is the official build from its developer and stays a separate program with
  its own service:
  - VLESS: the XTLS/Xray-core release for the router's CPU, checked against the published
    SHA-256, installed to `/usr/bin/xray` with the `geoip.dat` and `geosite.dat` from the
    same release in `/usr/share/xray`.
  - Hysteria 2: the apernet/hysteria release binary, checked against the published
    `hashes.txt`.
  - Naive: the klzgrad/naiveproxy OpenWrt build via `install-naive.sh`, checked against
    the SHA-256 digest GitHub publishes for the release file, **together with `dnsproxy`**
    (AdguardTeam/dnsproxy release for the router's CPU, e.g. `linux-arm64`; checked against
    its published SHA-256). One progress bar (Naive 0-70%, dnsproxy 70-100%); the card shows
    both versions and counts as installed only when both are present. Both files are replaced
    together after both downloads are verified; if the Naive service is running it is restarted
    once, with rollback of both files.
  - WireGuard: `kmod-wireguard`, `wireguard-tools` and `ip-full` from opkg.
- Free space is checked before anything is downloaded. If GitHub is not reachable
  directly, the download is retried through the local SOCKS entry of the active protocol.
  Only the service whose own binary is replaced is restarted, and only if it was running;
  the old files are put back if it does not start. Nothing is downloaded when the
  package is installed.
- New `vless.sh install xray|hy2|naive|wg` (runs in the background) and
  `vless.sh install-status`. Progress is written to `/tmp/aurora-install-<client>.json`.
- New helper scripts `install-client.sh` and `install-lib.sh` in
  `/usr/libexec/aurora-panel`. `install-naive.sh` can report progress.
- `INSTALL.md` and `README.md` describe the Install buttons.
- The product is now called **vpn.panel-gl.inet** (page title and header, README,
  INSTALL, package description). The page address is `/cgi-bin/vpn` instead of
  `/cgi-bin/vless`. The opkg package is **`vpn-panel-gl-inet`**; it replaces
  `aurora-router-panel` and `vless-router-panel`, so an install upgrades in place and
  keeps `/etc/xray/*` (links, `httpd.conf` login), `/etc/hysteria` and `/etc/naive`.
  The uhttpd section is `vpn_panel` (page files in `/www-vpn-panel`, helper scripts in
  `/usr/libexec/vpn-panel`); the old section, directories and autoupdate cron line are
  removed on install. The repository is
  `Xstrwe/vpn.panel-gl.inet` and the feed is now
  `https://xstrwe.github.io/vpn.panel-gl.inet/all` (the signing key is unchanged; the
  key file is `keys/vpn-panel-gl-inet.pub`). The old feed address no longer works: change
  the line in `/etc/opkg/customfeeds.conf` once (see `INSTALL.md`).
- The backend script is renamed from `/etc/xray/vless.sh` to `/etc/panel/vpn.sh`, and
  the CGI, init script, autoupdate and install helpers, tests and docs call the new path.
  Only the script moved: links, saved configs, `httpd.conf`, `proto`, `mode`, the
  `/etc/xray` helpers (`tproxy.sh`, `gen.uc`, `hy2.uc`) and all other user state stay
  where they were. The install removes the old `/etc/xray/vless.sh` and leaves no link
  under that name, so any own script that calls it must use `/etc/panel/vpn.sh` (same
  commands).
- The four VPN cards (VLESS, Naive, Hysteria2 and WireGuard) are compact and the
  same height. VLESS, Hysteria2 and WireGuard keep a fixed two-line address/link
  field, as in earlier versions, with no divider line under the field. On the
  Naive card, only **Server** and **Port** stay visible. **Username**, **Password**,
  **Scheme** and the other Advanced fields open in a small pop-up when the pointer
  hovers **Advanced**, and also on click or keyboard focus so the pop-up works on
  touch devices and with a keyboard. The **Advanced** trigger sits on the second
  row, left column, under Server (where the Username label used to be). The pop-up
  stays open while the pointer is inside it, and it does not change the card height.
  The Connect and Update now buttons sit about half a line lower, so they are not
  tight against the Auto-update row or the Advanced link. On the status card the
  row label is **Client:** (it was "Service (daemon):"). **Enable**, **Disable**,
  **Test connection** and **Speed** sit in that same card, directly under
  **Egress IP:** (about half a line of space above the buttons). Their result
  is shown under the buttons in the status card; the old separate button card
  is gone.
- Panel typography and buttons are consistent. Body text, status rows, inputs,
  selects, link fields (no longer monospace), hints, the Auto-update row and
  the action buttons all use the same 14px system sans-serif. Section headings
  (VPN, Proxy), card titles and the small field labels above inputs keep their
  own style. Every action button (Apply, Enable, Disable, Test connection,
  Speed, Connect, Update now, Add SOCKS5, Add HTTP, show/hide and Install)
  is the same compact size (14px text, 6px 12px padding, 30px height); colours
  are unchanged. The tiny service restart buttons and the Advanced text
  trigger stay as they were. The Mode row has no grey highlight or extra
  borders. In the Naive Advanced pop-up the Auto-update row stays on one
  line, like the other cards: Auto-update, the on checkbox, and Interval.
  In the status card, labels and values share the same 14px regular
  typeface. Green and red *state* values are bold (font-weight 700):
  Transparent mode ENABLED or DISABLED (or ERROR), and a running or
  failed Client name. Grey inactive client names, the Protocol value,
  Server and Egress IP stay regular weight, like the row labels. State
  is otherwise shown only by colour (green enabled/running, red
  disabled/failed, grey stopped/inactive).
- The SOCKS5 and HTTP cards have a close "×" in the top-right corner. It
  hides the card and brings back **Add SOCKS5** / **Add HTTP**. Saved
  proxy settings are not deleted: an unconfigured card still starts
  hidden, and a saved one still starts open. The `hidden` attribute
  still hides a button or card (`display:none` wins over the compact
  button layout).
- The Naive card follows the official NaiveProxy client config (klzgrad/naiveproxy
  README and USAGE.txt) instead of one `naive+https://` link field: separate **Server**
  and **Port** (default 443) fields stay on the card. **Username**, **Password** (with
  a show/hide button), **Scheme** (`https` or `quic`) and the optional keys upstream
  documents (`insecure-concurrency`, `extra-headers` (one per line), `tunnel-timeout`
  and `idle-timeout`), plus an optional **Subscription URL**, the auto-update row and
  **Update now**, are in the **Advanced** pop-up (auto-update re-fetches a subscription;
  it has nothing to do without one). `vpn.sh naivesave <file>` takes these fields as key=value
  lines (or, as before, a `naive+https://` / `naive+quic://` link), validates them (host
  name or IPv4, port 1-65535, one-line username and password) and writes
  `/etc/naive/config.json` with `"listen"` (unchanged: SOCKS `127.0.0.1:10828` and redir
  `:12366`), `"proxy": "<scheme>://<user>:<pass>@<host>:<port>"` (username and password
  percent-encoded) and `"host-resolver-rules": "MAP <host> <ip>"`. New `vpn.sh naive-show`
  prints the fields as JSON without the password.
- The saved Naive password is never written into the page: the field is empty with a
  "saved" placeholder, and leaving it empty keeps the saved password. Existing settings
  carry over without a save: the fields are read from `/etc/naive/config.json` (or, before
  the first save, from the saved link), and saving the same values writes the same file.
- The page decodes form fields with awk instead of `printf %b`, so a backslash in a
  password or a header stays a backslash.
- Status card: **Server:** shows only the active protocol's configured server host (the IP
  when it is configured by IP; no port, no SNI), and **Egress IP:** shows the egress IP
  followed by that server's port (`<egress-ip>:<port>`). Both come from the active
  protocol's own saved config.
- Removed the hints "IPv6 is not proxied." and "Local proxies for individual apps: ..."
  from the page (nothing else changed: the local proxy ports work as before).
- Fixed on a real GL-BE6500 (found while testing the buttons):
  - Install Naive found no build because the router reports its CPU as
    `aarch64_cortex-a53_neon-vfpv4`; the installer now also tries the name without the
    FPU suffix and the generic build of the CPU family.
  - Clients built with Go 1.24 or newer (current Xray and Hysteria 2) listen with MPTCP, and
    such a listener could not rebind its port while old connections were still in TIME_WAIT,
    so restarting Xray or Hysteria under traffic failed with "address already in use" for
    about a minute. The services of Xray, Hysteria 2 and dnsproxy now start with
    `GODEBUG=multipathtcp=0`; a restart takes about 5-10 seconds.
- The SOCKS5 and HTTP upstream cards hide the saved password the same way as Naive:
  the field is empty with a "saved" placeholder and a show/hide button, the password
  is never written into the page, and leaving the field empty keeps the saved
  password (the saved file is left unchanged when the other fields are the same).

## 1.5.0a4

Honest status: the panel no longer claims the network is working when it is not.
Pre-release.

- **Transparent mode** for the network is green **ENABLED** only when the active
  protocol really passes traffic (the same check the Test button runs). When
  transparent mode is on but the service is down or no traffic passes, it turns
  red **ERROR** and a banner at the top of the page says what caused it and how to
  fix it. When transparent mode is off it stays red **DISABLED**.
- **Test** and **Speed** now measure the active protocol through its own local
  entry (Xray, Hysteria, Naive or WireGuard). Before, they always went through the
  Xray SOCKS port, so with Naive or Hysteria active, Test reported
  "no connection (code 000)" even though traffic was passing.
- New `vless.sh health` (`off`, `down`, `broken`, `ok`, cached for 20 s) and
  `vless.sh probe 204|youtube|ip|speed`.

## 1.5.0a3

Every protocol is now fully independent: its own service, its own steering rules
and its own split file. Nothing goes through Xray except VLESS. Pre-release.

- **Hysteria2** runs alone (`hysteria-client`) with native `tcpRedirect`, `udpTProxy`
  and DNS forwarding listeners. **Naive** runs alone (`naive-client`) with its
  `redir` listener and `dnsproxy` for DNS over TCP. **WireGuard** runs alone
  (`wireguard-client`, kernel interface) with fwmark policy routing (table 871),
  masquerade and MSS clamp. Xray is stopped when it is not the active protocol.
- New `aurora-split.sh`: one nft table per protocol (`aurora_hy`, `aurora_nv`,
  `aurora_wg`) and one editable split file per protocol (`/etc/hysteria/split.conf`,
  `/etc/naive/split.conf`, `/etc/xray/wg.split.conf`). Hysteria 2 has no
  client-side ACL, so the split is done in nftables. New `aurora-geoip.sh` reads
  the country ranges from Xray's `geoip.dat` (BusyBox `hexdump`, no extra tools).
- Switching starts the target, checks a connection through the target's own local
  entry, switches its steering on, checks DNS, then stops the other protocols
  (including Xray when you leave VLESS). Any failure restores the target's files and
  keeps the previous protocol. A boot hook (`aurora-steer`) enables the steering
  only after the protocol works (fail open).
- Saving, autoupdating, restarting or updating the client of one protocol touches
  only that protocol. Autoupdate backup and rollback are per protocol; saving a
  Hysteria2 link never regenerates or restarts Xray.
- Hysteria2 and Naive store the server address as an IP (the name stays in the
  SNI / host-resolver rule), so reconnecting never needs DNS through the tunnel.
- `vless.sh client-update xray|hysteria|naive|wireguard check|install` updates one
  client from its own upstream (SHA-256 checked for Xray and hysteria) and restarts
  only that client.
- The service row shows grey for a daemon that is stopped because it is not the
  active protocol, red only when the active protocol's daemon is down. The Naive
  card and messages say "Naive". `vless.sh status` gained `active_up=` and reports the
  mode and the server address of the active protocol.
- The `xray-client` init script no longer turns transparent mode on when another
  protocol is active.
- Upgrading from 1.5.0a2 rebuilds the active Hysteria2/Naive/WireGuard config and
  brings it up as its own service.

## 1.5.0a2

- WireGuard is now its own service, like Naive and Hysteria. The new init
  script `wireguard-client` brings up a kernel interface `wg-aurora` from
  `/etc/xray/wg.json` (it needs `kmod-wireguard`, `wireguard-tools`, `ip-full`
  and `jq`). It does not touch the main routing table: only sockets bound to the
  interface use it, through policy routing (`ip rule oif wg-aurora`, table 871).
- With WireGuard as the active protocol, Xray's proxy outbound is a `freedom`
  outbound bound to `wg-aurora`, so the Russian-sites split (`ru` mode) and DNS
  work as with the other protocols. Switching to WireGuard starts the interface
  first and changes nothing if it cannot come up.
- The WireGuard ↻ button restarts only `wireguard-client` and never touches
  Xray or transparent mode. The service row shows the real state: running, not
  running, config not saved, or not installed (red, with the reason).
- `vless.sh status` reports `wireguard=` and `inst_wireguard=`. Switching to
  another protocol stops `wireguard-client`.
- The WireGuard endpoint name is resolved when the interface starts; the last
  good answer is kept in `/etc/xray/wg.resolved` in case DNS depends on the
  tunnel.
- Upgrading from a version that ran WireGuard inside Xray regenerates the
  config on install.

## 1.5.0a1

- Interface wording update.

## 1.5.0

Fix release for 1.4.0: restarting a service from the status card could leave
Xray down and transparent mode off.

### Fixed

- Xray restart: after the old Xray stops, the new one can fail to bind
  `0.0.0.0:12346` ("address already in use") for up to about a minute, because
  of connections left over from the old process. The restart now retries the
  start (clean stop in between, up to 75 s) instead of giving up after 15 s and
  leaving procd in a crash loop.
- Transparent mode is switched off while Xray is not listening, so the LAN is
  never redirected to a closed port, and is switched on again as soon as Xray
  listens. If the restart still fails, a detached `vless.sh recover` keeps
  trying (up to 6 more starts) and re-enables transparent mode when Xray is
  back, unless it was switched off on purpose.
- WireGuard runs inside Xray, so its ↻ button now does nothing and leaves Xray
  alone unless WireGuard is the connected protocol; in that case the button is
  greyed out with an explanation.
- Banners name the service that was pressed (for example
  `WIREGUARD (RUNS INSIDE XRAY): ...`) and give the concrete reason taken from
  `logread -e xray` (for example the port that could not be bound), plus a note
  when automatic recovery has been started.
- Restarting Xray never starts Naive or Hysteria: they are only touched by
  their own buttons or by switching the protocol.

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
