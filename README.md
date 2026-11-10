# Aurora-router-panel

A small web panel for OpenWrt / GL.iNet routers that runs a transparent proxy for the whole LAN through [Xray](https://github.com/XTLS/Xray-core) and lets you switch between **VLESS**, **Hysteria2**, **Naive** and **WireGuard** from a single page.

It ships as an `.ipk` package (`Architecture: all`, scripts only) plus a signed opkg feed on GitHub Pages, and is the successor of `vless-router-panel`.

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

2. Install it. Either add the signed opkg feed (recommended; later versions arrive with `opkg update && opkg upgrade`), see [Package feed](#package-feed):

   ```sh
   wget -O /etc/opkg/keys/2fa6e8de3e3e6f05 https://xstrwe.github.io/Aurora-router-panel/keys/2fa6e8de3e3e6f05
   echo 'src/gz aurora https://xstrwe.github.io/Aurora-router-panel/all' >> /etc/opkg/customfeeds.conf
   opkg update && opkg install aurora-router-panel
   ```

   or download the `.ipk` to `/tmp` first and install the file. **opkg on GL.iNet rejects URLs** ("Illegal file name"), so do not pass the URL to `opkg install`:

   ```sh
   cd /tmp
   wget -O vrp.ipk https://github.com/Xstrwe/Aurora-router-panel/releases/download/v1.3.0/aurora-router-panel_1.3.0_all.ipk
   opkg install /tmp/vrp.ipk
   rm -f /tmp/vrp.ipk
   ```

   Every [GitHub Release](https://github.com/Xstrwe/Aurora-router-panel/releases) has the `.ipk` and a `.sha256` file; the version is part of the file name. Check `opkg list-installed | grep aurora` after installing.

3. Open `http://192.168.8.1:8088`. If the installer printed a warning that no password is set, see [Authentication](#authentication) first.

4. Paste a `vless://` link into the VLESS card, press **Connect VLESS**, then **Enable**. The page should show the transparent mode as **ON**.

   To use Hysteria2, Naive or WireGuard, save the VLESS link first (it provides the base Xray config), then paste the link or config of the other protocol and press its **Connect …** button.

If the router's LAN address is not `192.168.8.1`, change `uhttpd.aurora.listen_http` with `uci` (or in LuCI) and restart uhttpd:

```sh
uci -q delete uhttpd.aurora.listen_http
uci add_list uhttpd.aurora.listen_http='<LAN-IP>:8088'
uci commit uhttpd && /etc/init.d/uhttpd restart
```

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

The page UI is currently in Russian; this README names every button and label by its English meaning.

- **Status card:** transparent mode, Xray state, active protocol, server host (with its SNI), and an on-demand exit-IP check.
- **Enable / Disable:** turn transparent mode on or off. When off, the LAN uses the internet directly.
- **Test connection / Speed:** connection and speed tests through the tunnel.
- **Mode:** "everything except Russian sites" (`ru`) or "everything through the tunnel" (`all`).
- **Protocol cards** (two columns on wide screens, one on narrow; each card is only as tall as its content): a field for the link or config, an auto-update row (checkbox and interval on one line), and the buttons **Connect …** and **Update now** side by side.

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
vless.sh autoset <proto> <0|1> <1h|6h|24h>   # auto-update on/off and interval
vless.sh src <proto> <infile> <outfile> <0|1> # link field input: an http(s) URL is remembered as the subscription source
vless.sh update <proto>     # run the autoupdate for one protocol now
```

After any change, check that `vless.sh status` shows `running=1` and `tproxy=1`.

### Authentication

The package does not invent a password. On first install it only creates a placeholder `/etc/xray/httpd.conf` containing comments (it never overwrites an existing one) and prints a warning. Until the file contains a real auth line, the page on port 8088 is open to everyone on the LAN.

The panel runs as its own uhttpd instance (`uhttpd.aurora`) with `config=/etc/xray/httpd.conf`. Each auth line has the form `<path-prefix>:<user>:<password>`. Add one line for the whole panel in either of these ways:

```sh
# Option A: reuse the router's own admin password (stored in /etc/shadow).
# "$p$root" tells uhttpd to look up the system user "root".
echo '/:root:$p$root' >> /etc/xray/httpd.conf

# Option B: a separate password. Generate a crypt hash and use it as the third field.
uhttpd -m 'your-password'            # prints the hash
echo '/:admin:<HASH>' >> /etc/xray/httpd.conf
```

Then restart uhttpd with `/etc/init.d/uhttpd restart` and check that `curl -s -o /dev/null -w '%{http_code}\n' http://192.168.8.1:8088/cgi-bin/vless` prints `401`. The comments in the placeholder file mention an older `/rfc2617 VLESS admin HASH` syntax; use the `/:user:password` form above instead. Never commit real passwords or hashes anywhere.

## Autoupdate

Each protocol card has an **Auto-update** row (an on/off checkbox and an interval of 1 h / 6 h / 24 h on one line) and two buttons: **Connect …** and **Update now**. There is no separate Save button and no separate update-URL field.

- The fresh config always comes from the protocol's own saved connection link, the one in the card's link field. If you put an `http(s)` subscription URL into that field, it is kept as the source and the link or config extracted from it is applied; a plain `vless://`, `hysteria2://`, `naive+https://` link or a WireGuard config cannot be re-fetched, so there is then nothing to update.
- **Connect** saves the auto-update settings and the link, then connects the protocol. **Update now** saves the auto-update settings and the link, then runs the update (a new direct link in the field is applied like Connect).
- A subscription may be plain text or base64; the first entry of the matching protocol is used. Downloads have a timeout and a 1 MiB limit.
- Cron runs `/usr/libexec/aurora-panel/autoupdate-run.sh` every hour and updates the protocols whose interval has elapsed.
- If the config did not change, nothing is touched. For the **active** protocol a changed config is applied immediately and verified with a request to `generate_204` through the local SOCKS port; on failure everything is rolled back and Xray is restarted. For other protocols the new config is only saved.
- Settings live in `/etc/xray/autoupdate/<proto>.conf` (`enabled`, `interval`); the subscription URL, if any, in `<proto>.src`. Both survive upgrades. Old `url=` and `source=` lines from earlier versions are ignored. Autoupdate is off until you enable it.

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

Start with `vless.sh status` (expect `running=1` and `tproxy=1`) and the logs: `logread -e xray`, `logread -e hysteria`, `logread -e naive`, `logread -e vless-autoupdate`.

### 1. Xray fails to start, "config rolled back" (port busy)

- **Symptom:** switching protocol or saving a link ends with "Xray failed to start, config rolled back"; `logread -e xray` shows `failed to listen TCP on 0.0.0.0:12346` (or `10808`) with `address already in use`; `vless.sh status` shows `running=0`.
- **Cause:** two Xray instances raced for the same ports, or an old instance had not exited yet. Since 1.3.0 the restart waits for Xray to exit, force-kills it if needed and waits for the ports to be free, but a stray process can still hold them.
- **Fix:**

  ```sh
  /etc/init.d/xray-client stop
  killall -9 xray 2>/dev/null; sleep 2
  netstat -lntu | grep -E ':(10808|12345|12346) '    # must print nothing
  /etc/init.d/xray-client start
  vless.sh status                                     # running=1, tproxy=1
  ```

  If the ports are still busy, `netstat -lntup | grep -E ':(10808|12345|12346) '` shows the owning process. If everything is stuck, use item 8.

### 2. Transparent mode is off (`tproxy=0`)

- **Symptom:** `vless.sh status` shows `tproxy=0`, or the page shows transparent mode as OFF while Xray runs; LAN devices use the internet directly. A working SOCKS test (`10808`) does not prove transparent mode works.
- **Cause:** the nftables table was removed, either because you pressed **Disable** (this creates `/etc/xray/tproxy.disabled`) or because a failed switch left it down.
- **Fix:**

  ```sh
  vless.sh on                  # removes tproxy.disabled, restarts Xray, brings the rules up
  # or just the rules:
  /etc/xray/tproxy.sh up
  nft list table inet xray >/dev/null && echo tproxy ok
  ```

### 3. No DNS (or slow DNS) while Naive is active

- **Symptom:** sites do not open under Naive, `nslookup google.com` on the router or `dig @192.168.8.1 google.com` from a LAN host times out.
- **Cause:** Naive carries TCP only. The panel therefore sends DNS through the tunnel as DNS over TCP, blocks QUIC (UDP 443) so browsers fall back to TCP, and sends other UDP directly. If Xray is down, or the Naive client or its server is unreachable, DNS fails too.
- **Fix:**

  ```sh
  vless.sh status                                  # proto=naive, running=1, tproxy=1
  ps w | grep -E 'naive|xray' | grep -v grep       # both must run
  logread -e naive | tail                          # connection errors to the server?
  nslookup google.com                              # on the router
  dig @192.168.8.1 google.com                      # from a LAN host
  ```

  If `/usr/bin/naive` is missing, run `/usr/libexec/aurora-panel/install-naive.sh`. If the Naive server cannot be reached, switch back with item 8.

### 4. The page shows 401 or you cannot log in

- **Symptom:** `http://192.168.8.1:8088` asks for a login and rejects it, or answers `401` to everything.
- **Cause:** the auth line in `/etc/xray/httpd.conf` does not match what you type: wrong user name, wrong password, or a malformed line. The browser may also be sending credentials cached for the old `VLESS` realm.
- **Fix:** look at the line without printing the hash, fix it, and restart uhttpd:

  ```sh
  grep -v '^#' /etc/xray/httpd.conf | cut -d: -f1,2     # path and user only
  ```

  The format is `/:<user>:<password>`. With `/:root:$p$root` the password is the router admin password of the system user `root`. For a separate password use a hash from `uhttpd -m 'your-password'`. Then:

  ```sh
  /etc/init.d/uhttpd restart
  curl -s -o /dev/null -w '%{http_code}\n' http://192.168.8.1:8088/cgi-bin/vless   # 401 without credentials
  ```

  Locked out completely? Delete the auth line from `/etc/xray/httpd.conf` over SSH and restart uhttpd; the page is then open to the LAN until you add a new line. Try a private browser window to rule out cached credentials. If the page does not load at all, check `uci show uhttpd.aurora` (listen address and port).

### 5. opkg: "Malformed package file" or the URL is not accepted

- **Symptom:** `opkg install <URL>` prints "Illegal file name", or installing the downloaded file prints "Malformed package file".
- **Cause:** opkg on GL.iNet does not accept URLs. A "Malformed package file" means the file is not a complete `.ipk`: a truncated download, an HTML error page, or a cached older file.
- **Fix:** download to `/tmp` first and compare size and checksum with the feed index:

  ```sh
  cd /tmp
  wget -O vrp.ipk https://github.com/Xstrwe/Aurora-router-panel/releases/download/v1.3.0/aurora-router-panel_1.3.0_all.ipk
  wget -O vrp.ipk.sha256 https://github.com/Xstrwe/Aurora-router-panel/releases/download/v1.3.0/aurora-router-panel_1.3.0_all.ipk.sha256
  ls -l vrp.ipk
  sha256sum vrp.ipk; cat vrp.ipk.sha256              # the two hashes must match
  tar tzf vrp.ipk                                    # must list ./debian-binary ./control.tar.gz ./data.tar.gz
  opkg install /tmp/vrp.ipk && rm -f /tmp/vrp.ipk
  ```

  If the checksum differs, download again. If `opkg update` reports a signature error for the `aurora` feed, the public key is missing or wrong: see [Package feed](#package-feed).

### 6. Auto-update does nothing

- **Symptom:** the config never changes, **Update now** says "nothing to update", or nothing appears in the log.
- **Cause (check in this order):**
  1. Auto-update is off for that protocol (the checkbox is cleared and saved).
  2. The link field does not hold an `http(s)` subscription URL (a plain `vless://` link or a WireGuard config cannot be re-fetched).
  3. The interval has not elapsed yet (cron runs hourly).
  4. The cron line is missing or cron is not running.
  5. The URL does not return an entry for that protocol, or the download fails.
  6. The update was applied to the active protocol, the connectivity check failed, and it was rolled back.
- **Fix:**

  ```sh
  cat /etc/xray/autoupdate/vless.conf                # enabled=1, interval=...  (use your protocol name)
  cat /etc/xray/autoupdate/vless.src                 # the subscription URL, if the field held one
  grep aurora /etc/crontabs/root                     # must contain autoupdate-run.sh
  /etc/init.d/cron enable; /etc/init.d/cron restart
  vless.sh update vless                              # run it now and read the message
  logread -e vless-autoupdate | tail
  curl -fsSL "$(cat /etc/xray/autoupdate/vless.src)" | head -c 300   # does it return the expected link or config?
  ```

### 7. Hysteria2 or WireGuard does not connect

- **Symptom:** after pressing **Connect Hysteria2** or **Connect WireGuard** the page reports an error, or it connects but there is no traffic (generate_204 fails).
- **Cause:** both use UDP. Many networks block or throttle UDP, or QUIC on a given port. For Hysteria2 the usual culprits are a missing `/usr/bin/hysteria`, a wrong password, SNI or port in the link, or a firewall in front of the server. WireGuard is experimental here: it runs through Xray's built-in outbound and needs a complete `.conf`; an MTU that is too large also stalls traffic.
- **Fix:**

  ```sh
  ls -l /usr/bin/hysteria                            # Hysteria2 only: the binary must exist
  /etc/init.d/hysteria-client status; logread -e hysteria | tail
  logread -e xray | tail                             # WireGuard handshake or routing errors
  curl -s -o /dev/null -w '%{http_code}\n' --socks5-hostname 127.0.0.1:10808 https://www.google.com/generate_204   # expect 204
  ```

  For WireGuard make sure the config has `[Interface]` with `PrivateKey` and `Address`, and `[Peer]` with `PublicKey`, `Endpoint` and `AllowedIPs`; try `MTU = 1280` in `[Interface]`. Test the server from another network, or fall back to VLESS (item 8).

### 8. No internet after switching protocol (restore VLESS)

- **Symptom:** after a switch the whole LAN has no internet, or the page and SSH still work but nothing loads.
- **Cause:** the new protocol's tunnel does not work, or the switch failed half-way and left transparent mode up without a working Xray (or down).
- **Fix:** give the LAN a direct connection first, then bring VLESS back and re-enable the rules:

  ```sh
  /etc/xray/tproxy.sh down          # LAN uses the internet directly right away
  vless.sh proto vless              # switch back to the saved VLESS link
  /etc/xray/tproxy.sh up
  vless.sh status                   # running=1, tproxy=1, proto=vless
  curl -s -o /dev/null -w '%{http_code}\n' --socks5-hostname 127.0.0.1:10808 https://www.google.com/generate_204   # 204
  ```

  If `vless.sh proto vless` fails, the saved VLESS link may be wrong: save it again on the page. If Xray itself will not start, see item 1.

## Package feed

Every round release (`X.Y.0`) is published as a GitHub Release and in a **signed opkg feed** on GitHub Pages: `https://xstrwe.github.io/Aurora-router-panel/all` (files `Packages`, `Packages.gz`, `Packages.sig` and the `.ipk`).

Packages are signed with [usign](https://git.openwrt.org/?p=project/usign.git), the same signature scheme OpenWrt uses for its own feeds, so `option check_signature 1` in `/etc/opkg.conf` can stay enabled. The public key is [`keys/aurora-router-panel.pub`](keys/aurora-router-panel.pub); its key ID is `2fa6e8de3e3e6f05`.

On the router:

```sh
# 1. trust the signing key (opkg looks keys up by key ID)
wget -O /etc/opkg/keys/2fa6e8de3e3e6f05 https://xstrwe.github.io/Aurora-router-panel/keys/2fa6e8de3e3e6f05

# 2. add the feed
echo 'src/gz aurora https://xstrwe.github.io/Aurora-router-panel/all' >> /etc/opkg/customfeeds.conf

# 3. install (and later upgrade)
opkg update
opkg install aurora-router-panel
```

Check that the key you downloaded is the right one: `cat /etc/opkg/keys/2fa6e8de3e3e6f05` must print the same second line as [`keys/aurora-router-panel.pub`](keys/aurora-router-panel.pub), `RWQvpujePj5vBTDs4E+JxMS904WhmHAzCtyBztpBnRiLTeSU5iMaIdFj`. The feed needs HTTPS support in opkg's downloader (`ca-bundle` and `libustream-*`, present on stock OpenWrt and GL.iNet firmware).

`Packages` lists only the newest version (pre-releases included); older `.ipk` files stay in the same directory. To pin or roll back a version, install the `.ipk` of that release from the GitHub Releases page. See [Versioning](#versioning).

## Versioning

- **Release versions** are `X.Y.0` (for example `1.3.0`, `1.4.0`). Each one is published as a full GitHub Release.
- **Pre-releases** are `X.Y.Z` followed by one letter and a number, for example `1.3.0a1`, `1.3.0a2`, `1.3.0b1`. Each one is published as a GitHub **pre-release** with the same assets (`.ipk` and `.sha256`).
- Any other version string (such as a plain `1.3.1`) is built by CI but not published.

opkg compares versions like dpkg: digit groups numerically, and a letter suffix sorts *after* the bare version. So `1.3.0 < 1.3.0a1 < 1.3.0a2 < 1.3.0a10 < 1.3.0b1 < 1.4.0`. This means a pre-release is *newer* than the round release with the same numbers: `1.3.0a1` is the first build after `1.3.0`, and the next round release is `1.4.0`. Use `a` for alpha and `b` for beta. `tests/version-order.sh` checks the ordering with a port of opkg's `verrevcmp` (`tools/vercmp.sh`) and, where `dpkg` is installed, cross-checks it against dpkg.

The signed Pages feed holds **every published version** as an `.ipk` file. `Packages` lists only the newest one, pre-releases included, so a router on the feed gets pre-releases with `opkg upgrade`. To stay on a full release, install its `.ipk` from the GitHub Releases page instead of using the feed, or pin the feed's package with `opkg flag hold aurora-router-panel`. An older version can always be downloaded by name from `https://xstrwe.github.io/Aurora-router-panel/all/aurora-router-panel_<version>_all.ipk`.

To publish: change `Version` in `control/control` (and add a `## <version>` section to `CHANGELOG.md`, which becomes the release notes), then merge to `main`; or push a matching tag `v<version>`; or run the "Release and publish opkg feed" workflow by hand from the Actions tab.

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

CI:

- `.github/workflows/build.yml` runs `build.sh` on every push and pull request touching the package files. On `main` it commits the rebuilt, unsigned `feed/` if it changed (kept for the existing raw URL; new installs should use the signed Pages feed above).
- `.github/workflows/release.yml` makes a release or pre-release (see [Versioning](#versioning)). It runs when `main` gets a change to `control/control` whose `Version` is `X.Y.0` or `X.Y.Z<letter><digits>`, when a matching tag `v<version>` is pushed (the tag must match the control `Version`), or by hand (Actions, "Run workflow"; it re-publishes the feed and refreshes the assets of an existing release). It builds the `.ipk` (running all tests), creates the tag and a GitHub Release (a pre-release for letter versions; notes taken from the matching `CHANGELOG.md` section, `.ipk` and `.sha256` attached), adds the `.ipk` to the files of all earlier releases, writes the index with `tools/mkfeed.sh`, signs `Packages` with the `USIGN_SECRET_KEY` Actions secret and deploys the feed to GitHub Pages. If no release exists for a version, a plain push of the version bump is enough. A `CHANGELOG.md` section named `## <version>` is required.
- `tests/` and `tools/` changes also run `build.sh`, which runs `tests/autoupdate.sh` and `tests/version-order.sh`.

Sources: `files/` (installed tree), `control/` (package metadata and maintainer scripts), `tests/`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](LICENSE).
