# pm-lib.sh: package-manager helpers shared by install-client.sh, install-naive.sh and
# client-update.sh. Sourced, not executed.
#
# OpenWrt up to 24.10 (and GL.iNet firmware based on it) uses opkg. OpenWrt 25.x and
# main use apk (apk-tools 3). The panel only needs a few verbs from either of them:
#   pm_name              prints opkg, apk or none
#   pm_update            refresh the package lists
#   pm_install PKG...    install packages (already installed ones are left as they are)
#   pm_upgrade PKG...    upgrade packages to the newest version in the lists
#   pm_version PKG       print the installed version of one package (empty when missing)
# AURORA_PM=opkg|apk forces one of them (used by the tests).

pm_name() {
	case "${AURORA_PM:-}" in
		opkg|apk) echo "$AURORA_PM"; return 0 ;;
	esac
	if command -v opkg >/dev/null 2>&1; then echo opkg
	elif command -v apk >/dev/null 2>&1; then echo apk
	else echo none; fi
}

pm_update() {
	case "$(pm_name)" in
		opkg) opkg update ;;
		apk) apk update ;;
		*) echo "no package manager (opkg or apk) found" >&2; return 1 ;;
	esac
}

pm_install() {
	case "$(pm_name)" in
		opkg) opkg install "$@" ;;
		apk) apk add "$@" ;;
		*) echo "no package manager (opkg or apk) found" >&2; return 1 ;;
	esac
}

pm_upgrade() {
	case "$(pm_name)" in
		opkg) opkg upgrade "$@" ;;
		apk) apk add -u "$@" ;;
		*) echo "no package manager (opkg or apk) found" >&2; return 1 ;;
	esac
}

pm_version() {
	case "$(pm_name)" in
		opkg) opkg list-installed "$1" 2>/dev/null | awk -v p="$1" '$1 == p {print $3; exit}' ;;
		# "wireguard-tools-1.0.20250521-r1 aarch64 {wireguard-tools} (GPL-2.0) [installed]"
		apk) apk list -I "$1" 2>/dev/null | awk -v p="$1" 'index($1, p "-") == 1 {print substr($1, length(p) + 2); exit}' ;;
	esac
}
