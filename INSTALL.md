# Install and set up Aurora-router-panel

Log in to the router over SSH as `root` (on the stock GL.iNet LAN address that is `ssh root@192.168.8.1`). The backend the page calls is `/etc/xray/vless.sh`; it is not on `PATH`, so the commands below use that full path.

## Requirements

The package itself depends on `curl`, `jq`, `ucode`, `uhttpd` and `kmod-nft-tproxy` (opkg installs these automatically).

The VPN clients are not inside the `.ipk`. After the panel is installed, the **Install VPN clients** block in the middle of the page installs the ones you need, one button per client (see [Install the VPN clients](#install-the-vpn-clients)). Nothing is downloaded when the package itself is installed.

| Protocol | Button | What it installs |
| --- | --- | --- |
| VLESS, and also SOCKS5/HTTP upstreams | **Install VLESS** | Xray-core from XTLS: `xray` at `/usr/bin/xray`, plus `geoip.dat` and `geosite.dat` in `/usr/share/xray/` |
| Hysteria 2 | **Install Hysteria 2** | the official `hysteria` client at `/usr/bin/hysteria` |
| Naive | **Install Naive** | the official `naive` client at `/usr/bin/naive` **and** `dnsproxy` from AdGuard, which Naive's service uses to send DNS through the tunnel. Both are installed by the one button (needs `xz`, which the button installs if it is missing) |
| WireGuard | **Install WireGuard** | `kmod-wireguard`, `wireguard-tools` and `ip-full` from the firmware's package manager (opkg) |

The “everything except Russian sites” split also reads `/usr/share/xray/geoip.dat`. Without Xray and the geo files you can still open the page, but you cannot connect VLESS, SOCKS5 or HTTP, and country-based split will not work.

## Install from the signed opkg feed (recommended)

The feed is `https://xstrwe.github.io/Aurora-router-panel/all`. Packages are signed with usign; the public key is [`keys/aurora-router-panel.pub`](keys/aurora-router-panel.pub) and its key ID is `2fa6e8de3e3e6f05`. Leave `option check_signature 1` in `/etc/opkg.conf` enabled. The feed needs HTTPS support in opkg (`ca-bundle` and `libustream-*`, present on stock OpenWrt and GL.iNet firmware).

```sh
wget -O /etc/opkg/keys/2fa6e8de3e3e6f05 https://xstrwe.github.io/Aurora-router-panel/keys/2fa6e8de3e3e6f05
echo 'src/gz aurora https://xstrwe.github.io/Aurora-router-panel/all' >> /etc/opkg/customfeeds.conf
opkg update && opkg install aurora-router-panel
```

Add the feed line only once. Check that the key file’s second line matches [`keys/aurora-router-panel.pub`](keys/aurora-router-panel.pub):

```
RWQvpujePj5vBTDs4E+JxMS904WhmHAzCtyBztpBnRiLTeSU5iMaIdFj
```

`Packages` lists only the newest published version, pre-releases included, so later `opkg update && opkg upgrade` may install a pre-release. To stay on a full release, install that release’s `.ipk` instead (see below) or pin the package with `opkg flag hold aurora-router-panel`.

Check the install with `opkg list-installed | grep aurora`.

## Install a `.ipk` by hand

Every [GitHub Release](https://github.com/Xstrwe/Aurora-router-panel/releases) has `aurora-router-panel_<version>_all.ipk` and a `.sha256` file. Older versions also stay at `https://xstrwe.github.io/Aurora-router-panel/all/aurora-router-panel_<version>_all.ipk`.

**opkg on GL.iNet rejects URLs** (“Illegal file name”). Download the file first; do not pass the URL to `opkg install`:

```sh
cd /tmp
wget -O vrp.ipk https://github.com/Xstrwe/Aurora-router-panel/releases/download/v<version>/aurora-router-panel_<version>_all.ipk
wget -O vrp.ipk.sha256 https://github.com/Xstrwe/Aurora-router-panel/releases/download/v<version>/aurora-router-panel_<version>_all.ipk.sha256
sha256sum vrp.ipk; cat vrp.ipk.sha256
opkg install /tmp/vrp.ipk
rm -f /tmp/vrp.ipk
```

Replace `<version>` with the version you want (for example a release listed on the Releases page). If the checksum differs, download again. `tar tzf vrp.ipk` must list `./debian-binary`, `./control.tar.gz` and `./data.tar.gz`.

## Open the panel

Open `http://192.168.8.1:8088`. The page redirects to `/cgi-bin/vless`. The panel is a separate uhttpd instance (`uhttpd.aurora`) listening on port **8088**.

If the router’s LAN address is not `192.168.8.1`:

```sh
uci -q delete uhttpd.aurora.listen_http
uci add_list uhttpd.aurora.listen_http='<LAN-IP>:8088'
uci commit uhttpd && /etc/init.d/uhttpd restart
```

Then open `http://<LAN-IP>:8088`.

### Optional: protect the page

The package does not set a password. On first install it only creates a placeholder `/etc/xray/httpd.conf` (it never overwrites an existing one) and prints a warning if that file has no auth line. Until you add one, the page on port 8088 is open to everyone on the LAN.

The installer looks for a line of the form `/<path>:<user>:<password>`. Generate a hash and add a line for the whole panel, then restart uhttpd:

```sh
uhttpd -m 'your-password'            # prints the hash; do not commit it
echo '/:admin:<HASH>' >> /etc/xray/httpd.conf
/etc/init.d/uhttpd restart
```

Use the hash in place of `<HASH>`, and any login you want in place of `admin`. A request without credentials to `http://192.168.8.1:8088/cgi-bin/vless` should then return `401`.

### Optional: Naive binary by hand

The **Install Naive** button does this for you. From the command line:

```sh
opkg update && opkg install xz
/usr/libexec/aurora-panel/install-naive.sh
```

The script installs the klzgrad/naiveproxy static build for this router’s architecture to `/usr/bin/naive`. It never touches an existing `/etc/naive/config.json`. Use `--force` to replace the binary, or pass a release tag or a direct archive URL. If the router cannot reach GitHub, copy the binary yourself (`scp` it to `/usr/bin/naive` and `chmod 755`).

## Install the VPN clients

Open the panel. In the middle of the page, under **Enable** / **Disable**, the **Install VPN clients** block has up to four buttons: **Install VLESS**, **Install Hysteria 2**, **Install Naive** and **Install WireGuard**. Only the clients that are not installed yet are listed (Naive counts as installed only when both `naive` and `dnsproxy` are present); when all four are installed, the whole block is not on the page. Press the one you need.

Under each button the panel shows a progress bar with a percent from 0 to 100 and the current step (checking the router, looking up the latest release, downloading, verifying, unpacking, installing). At the end the card shows:

- **Installed · version …** (green, 100%) when it worked; a moment later the card disappears, and so does the whole block once nothing is left to install;
- **Error: …** (red) with a short reason when it did not, for example not enough free space, GitHub not reachable, or a checksum mismatch;
- A client that is already on the router has no card. To update one, use the auto-update of the panel or the command line.

What each button does:

- **Install VLESS** downloads the latest release of [XTLS/Xray-core](https://github.com/XTLS/Xray-core) for the router’s CPU, checks it against the SHA-256 the project publishes, and installs `xray` to `/usr/bin` and the `geoip.dat` and `geosite.dat` files from the same release to `/usr/share/xray`.
- **Install Hysteria 2** downloads the latest [apernet/hysteria](https://github.com/apernet/hysteria) release binary and checks it against the published `hashes.txt`.
- **Install Naive** installs two programs with one progress bar: the latest [klzgrad/naiveproxy](https://github.com/klzgrad/naiveproxy) OpenWrt build (0–70%) and the latest [AdguardTeam/dnsproxy](https://github.com/AdguardTeam/dnsproxy) release for the router’s CPU (70–100%; `linux-arm64` on an aarch64 router). Each download is checked against the SHA-256 that GitHub publishes for the release file (for dnsproxy, `checksums.txt` is used if the release has no digest); if a checksum is missing or wrong the install stops and nothing is replaced. `dnsproxy` goes to the place where the Naive service looks for it (`/usr/bin/dnsproxy`, or the existing one on `PATH`). The card shows **Installed** only when both are present and lists both versions; if one is missing it says which. If the Naive service is running, it is restarted once (it starts its `dnsproxy` too), and both old files are put back if it does not start. It never touches `/etc/naive/config.json`.
- **Install WireGuard** runs `opkg update` and installs `kmod-wireguard`, `wireguard-tools` and `ip-full` (when they are already installed it upgrades the first two). The panel only sets up the client; a WireGuard server is your own.

Rules that apply to all four:

- Each client stays its own program with its own service. An install never changes a protocol setting or config and never starts, stops or switches a protocol.
- If the client you reinstall is running now, only that one service is restarted so it uses the new file. If it does not start, the old file is put back.
- The router needs free space first: about 70 MB in `/tmp` and 50 MB for the files for Xray, about 30 MB for Hysteria 2, about 55 MB for Naive with dnsproxy, a few MB for WireGuard. If there is not enough, the install stops before it downloads anything.
- If GitHub cannot be reached directly, the download is retried through the local SOCKS entry of the protocol that is active now (when it is running). WireGuard uses opkg and its own mirrors only.
- Only one install runs at a time. You can leave the page; the install keeps going and the progress shows again when you come back.

From the command line:

```sh
/etc/xray/vless.sh install xray|hy2|naive|wg      # start in the background
/etc/xray/vless.sh install-status [xray|hy2|naive|wg]   # JSON: installed, version, state, percent, stage, error
```

The progress of each install is also written to `/tmp/aurora-install-<xray|hy2|naive|wg>.json`.

## Set up the panel

The page title is **Aurora router panel**. A status card sits at the top, then **Enable** / **Disable**, **Test connection** and **Speed**, then the **Install VPN clients** block, then a **VPN** section and a **Proxy** section.

### Add a protocol and connect

Each protocol is independent: you can connect Hysteria 2, Naive or WireGuard without saving a VLESS link first. SOCKS5 and HTTP upstreams still need the Xray binary, because they run through Xray.

In the **VPN** section, paste into the matching card and press its **Connect …** button:

| Card | What to paste | Button |
| --- | --- | --- |
| **vless:// link** | a `vless://…` link, or an `http(s)://` subscription URL | **Connect VLESS** |
| **hysteria2:// link** | a `hysteria2://…` or `hy2://…` link, or a subscription URL | **Connect Hysteria2** |
| **naive+https:// link** | a `naive+https://…` link, or a subscription URL | **Connect Naive** |
| **WireGuard config (.conf)** | a standard WireGuard config (`[Interface]` with `PrivateKey` and `Address`, `[Peer]` with `PublicKey` and `Endpoint`; `AllowedIPs` defaults to `0.0.0.0/0` if omitted) | **Connect WireGuard** |

**Connect …** saves the card and makes that protocol the active one. If transparent mode was not turned off earlier, steering for the LAN is brought up as well. If the new protocol does not come up, its files and the previously active protocol are restored.

In the **Proxy** section, **Add SOCKS5** and **Add HTTP** reveal a form (Address, Port, Login, Password; HTTP also has **TLS**, **SNI**, and **do not verify the certificate**). If a proxy is already saved, its card is shown expanded. **Connect SOCKS5** / **Connect HTTP** saves the fields and applies them as the tunnel’s upstream. An HTTP upstream cannot carry UDP (QUIC is blocked, other UDP goes direct).

A small note under VPN says **IPv6 is not proxied.** Under Proxy, local proxies for individual apps are listed as SOCKS5 `192.168.8.1:10808` and HTTP `192.168.8.1:10809`. Those two LAN ports exist only while VLESS, SOCKS5 or HTTP is active (they are Xray’s). Hysteria 2 exposes SOCKS5 on `127.0.0.1:10818` and Naive on `127.0.0.1:10828`, for local use on the router only.

From the command line (write the link or config to a file first; never put real credentials in a ticket or a commit):

```sh
/etc/xray/vless.sh save <file>         # save a vless:// link and connect VLESS
/etc/xray/vless.sh hy2save <file>      # save a hysteria2:// link and connect Hysteria 2
/etc/xray/vless.sh naivesave <file>    # save a naive+https:// link and connect Naive
/etc/xray/vless.sh wgsave <file>       # save a WireGuard .conf and connect WireGuard
/etc/xray/vless.sh store vless|hy2|naive|wg|socks|http <file>   # save only, do not switch
```

### Transparent mode

**Enable** and **Disable** turn transparent mode on or off for the LAN.

- **Enable** removes `/etc/xray/tproxy.disabled`, starts the active protocol if needed, and installs its steering rules.
- **Disable** creates `/etc/xray/tproxy.disabled` and removes the steering rules. The LAN then uses the internet directly. A later **Connect …** will not turn steering back on until you press **Enable**.

```sh
/etc/xray/vless.sh on
/etc/xray/vless.sh off
```

### Split mode (Russian sites direct)

The first row of the status card is **Mode:** with **Apply**.

- **Everything except Russian sites** (`ru`) — Russian sites and `geoip:ru` ranges go direct; everything else goes through the tunnel. This is the default.
- **Everything through the tunnel** (`all`) — all steered traffic goes through the tunnel. Private ranges and the proxy server itself always bypass the tunnel.

```sh
/etc/xray/vless.sh mode ru
/etc/xray/vless.sh mode all
```

The setting is applied only to the active protocol (VLESS/SOCKS5/HTTP store it in Xray routing; Hysteria 2, Naive and WireGuard each have their own split file).

### Read the status

The row **Transparent mode for the network:** is honest: it is green only when traffic actually passes through the active protocol (the same check as **Test connection**).

| Label | Colour | Meaning |
| --- | --- | --- |
| **ENABLED** | green | Steering is on, the active protocol is running, and a request through its own entry succeeds |
| **ERROR** | red | Steering is on, but the service is down or no traffic passes. A banner at the top of the page gives the cause (red) and how to fix it (green) |
| **DISABLED (direct internet)** | red | Steering is not installed; the LAN uses the internet directly |

The status card also shows:

- **Service (daemon):** Xray, Naive, Hysteria and WireGuard. Green if that daemon is running, red and bold if the *active* protocol’s daemon is not running, grey if a daemon is stopped because it is not the active protocol (that is normal: only one runs). Each name has a small restart button that restarts only that service. A service that is not installed, or WireGuard with no saved config, is shown red with the reason, and its restart button is disabled.
- **Protocol:** the protocol last applied by a **Connect …** button.
- **Server:** host (and SNI, or “no SNI” for WireGuard).
- **Egress IP:** the public address seen through the live tunnel, filled in after the page has loaded so a dead tunnel never delays the page. If it cannot be determined, the row says **could not determine**.

From the command line:

```sh
/etc/xray/vless.sh status
/etc/xray/vless.sh health
```

`status` prints `running=` (Xray), `hysteria=`, `naive=`, `wireguard=`, `inst_*`, `wg_conf=`, `tproxy=` (steering present), `active_up=` (the active protocol’s own service is up), `mode=`, `proto=` and `server_ip=`. `health` is the honest check used by the page: `ok` (passes traffic), `down` (steering on but the service is not running), `broken` (the service runs but the probe fails), or `off` (direct internet). After a change you want `health` to print `ok`, and `status` to show `tproxy=1` and `active_up=1`.

### Test connection and Speed

**Test connection** and **Speed** always measure through the *active* protocol’s own local entry (Xray SOCKS `127.0.0.1:10808`, Hysteria 2 SOCKS `127.0.0.1:10818`, Naive SOCKS `127.0.0.1:10828`, or the WireGuard interface `wg-aurora`). They never go through another protocol.

- **Test connection** reports whether `https://www.google.com/generate_204` succeeds, the latency, the egress IP, and whether YouTube opens.
- **Speed** downloads a test file through the same entry and reports Mbit/s for the active protocol, or **Speed: could not measure**.

```sh
/etc/xray/vless.sh probe 204
/etc/xray/vless.sh probe youtube
/etc/xray/vless.sh probe ip
/etc/xray/vless.sh probe speed
```

### Switch protocols

Press **Connect …** on the protocol you want (the saved link or config can stay as it is). Only that protocol’s service is started; if the switch succeeds, the others are stopped. If it fails, the previous protocol stays active.

To switch to an already saved protocol without pasting the link again:

```sh
/etc/xray/vless.sh proto vless
/etc/xray/vless.sh proto hy2
/etc/xray/vless.sh proto naive
/etc/xray/vless.sh proto wg
/etc/xray/vless.sh proto socks
/etc/xray/vless.sh proto http
```

A per-service restart (the small button, or the command below) does not change the active protocol:

```sh
/etc/xray/vless.sh restart-svc xray
/etc/xray/vless.sh restart-svc hysteria
/etc/xray/vless.sh restart-svc naive
/etc/xray/vless.sh restart-svc wireguard
/etc/xray/vless.sh restart          # full restart of the active protocol
```

### Auto-update

Each VPN card has an **Auto-update** row: a checkbox labelled **on**, an **Interval** of **1 hour** / **6 hours** / **24 hours**, plus **Connect …** and **Update now**.

The fresh config always comes from that card’s field. If the field holds an `http(s)` subscription URL, it is remembered as the source and the first matching entry is applied (plain text or base64; 1 MiB limit). A plain `vless://`, `hysteria2://`, `naive+https://` link or a WireGuard config cannot be re-fetched, so there is then nothing to update.

**Connect …** saves the auto-update settings and the link, then connects. **Update now** saves the settings and the link, then runs the update (a new direct link in the field is applied like Connect). Cron runs `/usr/libexec/aurora-panel/autoupdate-run.sh` every hour. Autoupdate is off until you enable it.

If the active protocol’s new config breaks the connection, the previous files of *that* protocol only are restored. Other protocols are not touched.

```sh
/etc/xray/vless.sh autoset vless|hy2|naive|wg <0|1> <1h|6h|24h>
/etc/xray/vless.sh update vless|hy2|naive|wg
```

### Update clients

Each client is updated from its own upstream, and only that client’s service is restarted (and only if it is already running):

```sh
/etc/xray/vless.sh client-update xray check
/etc/xray/vless.sh client-update xray install
/etc/xray/vless.sh client-update hysteria check|install
/etc/xray/vless.sh client-update naive check|install
/etc/xray/vless.sh client-update wireguard check|install
```

- Xray is taken from XTLS/Xray-core, Hysteria from apernet/hysteria; both are checked against the SHA-256 published with the release. The previous binary is kept as `<binary>.bak` and put back if the new one does not start.
- Naive is installed by `/usr/libexec/aurora-panel/install-naive.sh` (the naive part of the **Install Naive** button; the button also installs `dnsproxy`).
- WireGuard is upgraded with `opkg upgrade kmod-wireguard wireguard-tools`. The running interface keeps the old kernel module until you reboot.

## Backup and rollback

There is no separate backup button on the page. What the package already does:

- **Your links and configs are never overwritten** by an install or an upgrade. State that is kept includes `/etc/xray/{link.txt,config.json,hy2.txt,naive.txt,wg.conf,wg.json,wg.resolved,socks.json,http.json,server_ip,mode,proto,httpd.conf}`, `/etc/xray/autoupdate/*`, `/etc/hysteria/client.yaml`, `/etc/naive/config.json`, `/usr/bin/naive` and `dnsproxy`.
- **A failed Connect or protocol switch** restores that protocol’s files and keeps the previously active protocol.
- **A failed auto-update** of the active protocol restores that protocol’s files and reapplies the previous config (`no internet after the update, config rolled back`). An update of a protocol that is not active is only saved; on failure those files are rolled back too.
- **A failed client-binary update** puts the previous binary (`*.bak`) back.
- **To roll the package itself back**, install the `.ipk` of the earlier version from the Releases page or from `https://xstrwe.github.io/Aurora-router-panel/all/aurora-router-panel_<version>_all.ipk` (same “download, then `opkg install /tmp/vrp.ipk`” steps as above). Your saved links stay in place.

To copy the saved state off the router before a change, copy those files (they contain credentials; keep the copy private).

## Upgrade and uninstall

Install a newer `.ipk` the same way as above, or `opkg update && opkg upgrade` if you use the feed.

`aurora-router-panel` replaces `vless-router-panel`. Settings under `/etc/xray`, `/etc/hysteria` and `/etc/naive`, and the active protocol, are preserved. `/etc/xray/vless.sh` and the page address `/cgi-bin/vless` stay the same.

```sh
opkg remove aurora-router-panel
```

This removes the panel, its uhttpd section and the autoupdate cron line. It does not stop Xray, Hysteria, Naive or WireGuard, so a working transparent proxy keeps running. Saved links, configs `/usr/bin/naive` and `/usr/bin/dnsproxy` stay on the router; delete them yourself if you no longer need them.

## Command reference

`/etc/xray/vless.sh` also accepts:

```sh
/etc/xray/vless.sh status
/etc/xray/vless.sh health
/etc/xray/vless.sh egress
/etc/xray/vless.sh on | off
/etc/xray/vless.sh mode ru|all
/etc/xray/vless.sh proto vless|hy2|naive|wg|socks|http
/etc/xray/vless.sh save|hy2save|naivesave|wgsave <file>
/etc/xray/vless.sh store vless|hy2|naive|wg|socks|http <file>
/etc/xray/vless.sh restart
/etc/xray/vless.sh restart-svc xray|naive|hysteria|wireguard
/etc/xray/vless.sh client-update xray|hysteria|naive|wireguard check|install
/etc/xray/vless.sh install xray|hy2|naive|wg
/etc/xray/vless.sh install-status [xray|hy2|naive|wg]
/etc/xray/vless.sh autoset <proto> <0|1> <1h|6h|24h>
/etc/xray/vless.sh update <proto>
/etc/xray/vless.sh probe 204|youtube|ip|speed
```

Useful logs: `logread -e xray`, `logread -e hysteria`, `logread -e naive`, `logread -e vless-autoupdate`, `logread -e aurora`.
