# Aurora-router-panel

A web panel for the **GL.iNet GL-BE6500** (OpenWrt 23.05 based firmware) that runs a transparent proxy for the whole LAN. It is a scripts-only OpenWrt package (`Architecture: all`) and is developed and tested on that router. The package does not declare any other supported models. The code assumes the LAN bridge is `br-lan` and, by default, serves the panel at `http://192.168.8.1:8088`.

After you install the panel, these protocols can be used (only one is active at a time; each has its own service, config, split rules, restart and updates, and none of them goes through another):

- **VLESS (Xray)** — official Xray-core at `/usr/bin/xray`, with `geoip.dat` and `geosite.dat` in `/usr/share/xray/`. These files are not shipped in the package; the **Install VLESS** button on the panel page installs them. Required for VLESS, and also for SOCKS5/HTTP upstreams and for the “Russian sites direct” split (which reads `geoip.dat`).
- **Hysteria 2** — official hysteria client at `/usr/bin/hysteria` (optional; not in the package; the **Install Hysteria 2** button installs it).
- **Naive** — official naive client at `/usr/bin/naive` (optional; not in the package; the **Install Naive** button installs it together with `dnsproxy`, which Naive uses for DNS through the tunnel). Naive carries TCP only.
- **WireGuard** — implemented as a native kernel client (`wireguard-client`, interface `wg-aurora`). It is usable once `kmod-wireguard`, `wireguard-tools` and `ip-full` are installed (the **Install WireGuard** button does it) and you paste a standard WireGuard `.conf`. The panel does not set up a WireGuard server.

The clients are not inside the `.ipk`, and nothing is downloaded when the package is installed. In the middle of the page, four buttons — **Install VLESS**, **Install Hysteria 2**, **Install Naive** and **Install WireGuard** — install the official client from its developer on demand. Each shows a progress bar from 0 to 100% and, when done, the installed version.

The panel also has **SOCKS5** and **HTTP** upstreams (they run through Xray). IPv6 is not proxied.

Install and set the panel up: see [INSTALL.md](INSTALL.md).

Changelog: [CHANGELOG.md](CHANGELOG.md). License: MIT, see [LICENSE](LICENSE).
