#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
#
# Switch an existing Arch Linux ARM installation from SDDM to Plasma Login
# Manager.  The rootfs image builder installs PLM directly and does not need
# this script, but update packages must handle devices created before PLM was
# the default display manager.

set -eu
CDPATH=

root=${CAIHONG_PLATFORM_ROOT:-/}
systemctl_tool=${CAIHONG_SYSTEMCTL:-systemctl}
case $root in
	/|/*) ;;
	*) echo "invalid CAIHONG_PLATFORM_ROOT: $root" >&2; exit 2 ;;
esac

if [ "${CAIHONG_PLATFORM_SKIP_DISPLAY_MANAGER:-0}" = 1 ]; then
	exit 0
fi

# Only the incremental update installer is allowed to replace SDDM.  Image
# builders install and enable PLM themselves and must not run this migration.
if [ "${CAIHONG_PLATFORM_UPDATE_INSTALL:-0}" != 1 ]; then
	exit 0
fi

if [ ! -x "$root/usr/bin/pacman" ]; then
	# The platform package is also used for non-Arch distributions.  Leave
	# their display manager alone.
	exit 0
fi

run_systemctl()
{
	if [ "$root" = / ]; then
		"$systemctl_tool" "$@"
	else
		"$systemctl_tool" --root="$root" "$@"
	fi
}

alias=$root/etc/systemd/system/display-manager.service

# A display manager can be enabled without updating display-manager.service,
# for example `systemctl enable ly.service`.  Treat any explicitly enabled
# third-party manager as an administrator choice even if the alias still points
# at stock SDDM.
for unit in \
	gdm.service gdm3.service lightdm.service ly.service greetd.service \
	lemurs.service lxdm.service nodm.service slim.service wdm.service \
	xdm.service cosmic-greeter.service; do
	if run_systemctl is-enabled --quiet "$unit" >/dev/null 2>&1; then
		echo "keeping administrator-enabled display manager: $unit" >&2
		exit 0
	fi
done

# Never override a display manager that the administrator selected through the
# display-manager.service alias.  Only the stock SDDM selection, an empty
# selection, or an existing PLM selection is migrated automatically.
if [ -L "$alias" ]; then
	target=$(readlink -- "$alias")
	case $target in
		*/sddm.service|*/plasmalogin.service) ;;
		*)
			echo "keeping administrator-selected display manager: $target" >&2
			exit 0
			;;
	esac
fi

if [ ! -e "$root/usr/lib/systemd/system/plasmalogin.service" ]; then
	echo "plasmalogin.service is missing; install the plasma-login-manager dependency" >&2
	exit 1
fi

# SDDM and PLM share the display-manager.service alias.  Remove the stale
# alias before enabling PLM; systemctl will not replace an existing alias.
if [ -L "$alias" ]; then
	rm -f -- "$alias"
fi
run_systemctl enable plasmalogin.service >/dev/null

echo "Plasma Login Manager is now the active display manager" >&2
