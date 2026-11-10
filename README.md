# Aurora-router-panel

A small web panel for OpenWrt / GL.iNet routers that runs a transparent proxy for the whole LAN through [Xray](https://github.com/XTLS/Xray-core) and lets you switch between **VLESS**, **Hysteria2**, **Naive** and **WireGuard** from a single page.

It ships as an `.ipk` package (`Architecture: all`, scripts only) plus an unsigned opkg feed, and is the successor of `vless-router-panel`.

## Features

- Switch the active protocol with one button: **VLESS (Reality)**, **Hysteria2**, **Naive** or **WireGuard** (through Xray's built-in outbound; no `wireguard-tools` needed).
- **Transparent mode** for the LAN: TCP is redirected and UDP is TPROXY'd to Xray with nftables. Local and private ranges and the proxy server itself bypass the tunnel. DNS from the router and the LAN is handled by Xray.
- Routing modes: everything except Russian sites goes through the tunnel (`ru`), or everything does (`all`).
- **Per-protocol autoupdate** of the config from a subscription or link, with automatic rollback if the new config breaks the connection.
- Connection test (latency, exit IP, YouTube) and a speed test from the page.
- Web panel on port 8088 with optional HTTP basic auth. SOCKS5 (`:10808`) and HTTP (`:10809`) proxies are also exposed on the LAN address for individual apps.
- Safe by default: installing or removing the package never stops a working proxy, and your links and configs are never overwritten.

## Supported hardware and software

- Developed and tested on the **GL.iNet GL-BE6500** with **OpenWrt 23.05** (`aarch64_cortex-a53`). Other OpenWrt 23.05 routers with nftables and enough flash should work, but are untested. The LAN bridge is assumed to be `br-lan` with the router at `192.168.8.1`.
- IPv6 is not proxied.
- The WireGuard option is experimental.

## Requirements

Installed automatically from the OpenWrt feeds (package dependencies): `curl`, `jq`, `ucode`, `uhttpd`, `kmod-nft-tproxy`.

Install manually (not shipped in the package):

- `xray` at `/usr/bin/xray`
- `geoip.dat` and `geosite.dat` in `/usr/share/xray/`
- optional: `hysteria` at `/usr/bin/hysteria` (only for Hysteria2)
- optional: `naive` at `/usr/bin/naive` (only for Naive), installed by the helper script below; it needs the `xz` package to unpack the archive

Without `xray` and the geo files the page installs, but you cannot save a link or enable transparent mode.

## Installation

1. Log in to the router (the password is your router admin password; away from home you can use GoodCloud Remote SSH):

   ```sh
   ssh root@192.168.8.1
   ```

2. Download the package to `/tmp` first and install the file. **opkg on GL.iNet rejects URLs** ("Illegal file name"), so do not pass the URL to `opkg install`:

   ```sh
   cd /tmp
   wget -O vrp.ipk https://raw.githubusercontent.com/Xstrwe/Aurora-router-panel/main/feed/all/aurora-router-panel_1.3.0_all.ipk
   opkg install /tmp/vrp.ipk
   rm -f /tmp/vrp.ipk
   ```

   The version is part of the file name; take the current one from the [`feed/all`](feed/all) directory. `raw.githubusercontent.com` may cache a freshly merged file for a few minutes, so check `opkg list-installed | grep aurora` after installing.

3. Open `http://192.168.8.1:8088`. If the installer warned that no password is set, see [Authentication](#authentication) first.

4. Paste a `vless://` link and press **Подключить VLESS**, then **Включить**. The page should show the transparent mode as **ВКЛЮЧЁН**. To use Hysteria2, Naive or WireGuard, save the VLESS link first (it provides the base Xray config), then press the button of the protocol you want.

### Optional: Naive binary

```sh
opkg update && opkg install xz
/usr/libexec/aurora-panel/install-naive.sh
```

The script picks the static build for your architecture from the klzgrad/naiveproxy releases and installs it to `/usr/bin/naive`. It never touches an existing `/etc/naive/config.json`. Useful options: `--force` to replace the binary, or a release tag / direct archive URL as an argument. If the router cannot reach GitHub, copy the binary yourself: `scp naive root@192.168.8.1:/usr/bin/naive && ssh root@192.168.8.1 chmod 755 /usr/bin/naive`.

## Upgrading

Install the new `.ipk` the same way as above. Files that are not part of the package are kept: `/etc/xray/{link.txt,config.json,hy2.txt,naive.txt,wg.conf,wg.json,server_ip,mode,proto,httpd.conf}`, `/etc/xray/autoupdate/*`, `/etc/hysteria/client.yaml`, `/etc/naive/config.json` and `/usr/bin/naive`.

### Upgrading from `vless-router-panel`

`aurora-router-panel` declares `Replaces` and `Conflicts: vless-router-panel`, so a plain `opkg install /tmp/vrp.ipk` replaces the old package. All your settings under `/etc/xray`, `/etc/hysteria` and `/etc/naive`, and the active protocol, are preserved. What moves:

| Old | New |
| --- | --- |
| package `vless-router-panel` | `aurora-router-panel` |
| `/usr/libexec/vless-panel` | `/usr/libexec/aurora-panel` |
| `/www-vless` | `/www-aurora` |
| uhttpd section `uhttpd.vless` | `uhttpd.aurora` (same listen address and port) |
| cron mark `vless-router-panel-autoupdate` | `aurora-router-panel-autoupdate` (line rewritten) |

`/etc/xray/vless.sh` and the page address `/cgi-bin/vless` stay the same. The old GitHub URL redirects to the new repository.

## Usage

### The page

- **Status card:** transparent mode, Xray state, active protocol, server host (with its SNI), and an on-demand exit-IP check.
- **Включить / Выключить:** turn transparent mode on or off. When off, the LAN uses the internet directly.
- **Тест подключения / Скорость:** connection and speed tests through the tunnel.
- **Режим:** `ru` (everything except Russian sites) or `all`.
- **Protocol cards** (two columns on wide screens, one on narrow): a field for the link or config, a **Подключить …** button, and an autoupdate block.

### Command line

`/etc/xray/vless.sh` is the backend the page calls. It takes a file for the link-based commands:

```sh
vless.sh save <file>        # save a vless:// link and connect VLESS
vless.sh hy2save <file>     # save a hysteria2:// link and connect Hysteria2
vless.sh naivesave <file>   # save a naive+https:// link and connect Naive
vless.sh wgsave <file>      # save a WireGuard .conf and connect WireGuard
vless.sh proto vless|hy2|naive|wg   # switch to an already saved protocol
vless.sh mode ru|all
vless.sh on | off           # transparent mode on / off
vless.sh status             # running=, tproxy=, mode=, proto=, server_ip=
vless.sh autoset <proto> <0|1> <url> <1h|6h|24h>
vless.sh update <proto>     # run the autoupdate for one protocol now
```

After any change, check that `vless.sh status` shows `running=1` and `tproxy=1`.

### Authentication

The package does not invent a password. Until `/etc/xray/httpd.conf` contains a basic-auth line, the page on port 8088 is open to everyone on the LAN. To enable a login:

```sh
uhttpd -m 'your-password'          # prints a password hash
# add one line to /etc/xray/httpd.conf:  /:admin:<HASH>
/etc/init.d/uhttpd restart
```

Never commit real passwords or hashes anywhere.

## Autoupdate

Each protocol card has an **Автообновление** block: an on/off checkbox, a link field, an interval (1 h / 6 h / 24 h), and the buttons **Сохранить** and **Обновить сейчас**.

- The fresh config comes from the protocol's own source: the link in that field. If the field is empty, the protocol's saved connection link is used, but only when it is an `http(s)` subscription URL. A plain `vless://`, `hysteria2://`, `naive+https://` link or a WireGuard config cannot be re-fetched, so there is then nothing to update.
- A subscription may be plain text or base64; the first entry of the matching protocol is used. Downloads have a timeout and a 1 MiB limit.
- Cron runs `/usr/libexec/aurora-panel/autoupdate-run.sh` every hour and updates the protocols whose interval has elapsed.
- If the config did not change, nothing is touched. For the **active** protocol a changed config is applied immediately and verified with a request to `generate_204` through the local SOCKS port; on failure everything is rolled back and Xray is restarted. For other protocols the new config is only saved.
- Settings live in `/etc/xray/autoupdate/<proto>.conf` and survive upgrades. Autoupdate is off until you enable it.

## File layout

| Path | Purpose |
| --- | --- |
| `/etc/xray/vless.sh` | backend: save, switch, update, status |
| `/etc/xray/tproxy.sh` | nftables rules for transparent mode (`up` / `down`) |
| `/etc/xray/gen.uc`, `hy2.uc` | config generators (ucode) |
| `/etc/init.d/xray-client`, `hysteria-client`, `naive-client` | procd services |
| `/www-aurora/cgi-bin/vless` | the web page (CGI), served by uhttpd on :8088 |
| `/usr/libexec/aurora-panel/` | autoupdate library and runner, `install-naive.sh` |
| `/etc/xray/` (state) | saved links, `config.json`, `proto`, `mode`, `httpd.conf`, `autoupdate/` |
| `/etc/hysteria/client.yaml`, `/etc/naive/config.json` | Hysteria2 / Naive client configs |

Local ports: Xray SOCKS `10808`, HTTP `10809`, redirect (TCP) `12346`, TPROXY (UDP) `12345`, Xray DNS `5354`; Hysteria2 SOCKS `10818`; Naive SOCKS `10828`.

## Troubleshooting

- **"Xray не запустился, конфиг откатан" / "failed to listen ... address already in use".** Two Xray instances raced for ports 10808 or 12346. Since 1.3.0 the restart waits for Xray to exit, force-kills it if needed, waits for the ports to free up, and then waits for the new instance to listen. Manual fix: `/etc/init.d/xray-client stop; killall -9 xray; sleep 2; netstat -lntu | grep -E ':(10808|12345|12346) '` (must print nothing), then `/etc/init.d/xray-client start` or `vless.sh proto <current>`.
- **Transparent mode is OFF** (`tproxy=0` or the page shows ВЫКЛЮЧЕН while Xray runs). Check `vless.sh status`, then run `/etc/xray/tproxy.sh up`. If you turned it off on purpose, `/etc/xray/tproxy.disabled` exists; `vless.sh on` removes it. A SOCKS test alone does not prove transparent mode works, so check `tproxy=1`.
- **No internet for the whole LAN.** Run `/etc/xray/tproxy.sh down` to give the LAN direct access, then `vless.sh proto vless` and `/etc/xray/tproxy.sh up`.
- **DNS under Naive.** Naive is TCP-only. The panel therefore sends DNS through the tunnel as DNS-over-TCP, blocks QUIC (UDP 443) so browsers fall back to TCP, and sends other UDP directly. If lookups fail, check on the router with `nslookup google.com` and from a LAN host with `dig @192.168.8.1 google.com`.
- **Naive "Сначала установи naive".** `/usr/bin/naive` is missing; run the install script above.
- **`opkg install` says "Illegal file name" or "Malformed package file".** You passed a URL, or the file is incomplete or not an `.ipk` (for example an HTML error page). Download with `wget -O /tmp/vrp.ipk ...` and compare the size and checksum with `feed/all/Packages`.
- **`opkg update` complains about the feed signature.** The feed is unsigned. Prefer installing from a downloaded file; see the next section.

## Package feed (optional)

Feed URL: `https://raw.githubusercontent.com/Xstrwe/Aurora-router-panel/main/feed/all`. The feed is **unsigned**, while OpenWrt 23.05 normally has `option check_signature 1` in `/etc/opkg.conf`, which applies to all feeds at once. The simplest and safest way is to install from the downloaded `.ipk` as shown above. If you still want `opkg update` to work, add `src/gz aurora_panel <feed URL>` to `/etc/opkg/customfeeds.conf`, temporarily comment out `check_signature`, run `opkg update && opkg install aurora-router-panel`, and restore the option afterwards.

## Uninstall

```sh
opkg remove aurora-router-panel
```

This removes the panel, its uhttpd section and the autoupdate cron line. It does not stop Xray, Hysteria or Naive, so a working transparent proxy keeps running. Your saved links and configs, `/usr/bin/naive` and the other state files stay on the router; delete them by hand if you no longer need them (`rm -rf /etc/xray/autoupdate` etc.).

## Building from source

```sh
./build.sh
```

`build.sh` assembles a reproducible `.ipk` (a gzip-compressed tar with `./debian-binary`, `./control.tar.gz`, `./data.tar.gz`, owner `root:root`, fixed timestamps), writes `feed/all/Packages` and `Packages.gz`, syntax-checks all shell scripts, unpacks the result to verify its contents, and runs `tests/autoupdate.sh`. It needs GNU tar and gzip. The package version is taken from `control/control`.

CI (`.github/workflows/build.yml`) runs `build.sh` on every push and pull request touching the package files. On `main` it commits the rebuilt `feed/` if it changed.

Sources: `files/` (installed tree), `control/` (package metadata and maintainer scripts), `tests/`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](LICENSE).
