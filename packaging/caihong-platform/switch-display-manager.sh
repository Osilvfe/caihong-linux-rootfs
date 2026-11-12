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
chroot_tool=${CAIHONG_CHROOT_TOOL:-chroot}
systemctl_tool=${CAIHONG_SYSTEMCTL:-systemctl}
case $root in
	/|/*) ;;
	*) echo "invalid CAIHONG_PLATFORM_ROOT: $root" >&2; exit 2 ;;
esac

if [ "${CAIHONG_PLATFORM_SKIP_DISPLAY_MANAGER:-0}" = 1 ]; then
	exit 0
fi

if [ ! -x "$root/usr/bin/pacman" ]; then
	# The platform package is also used for non-Arch distributions.  Leave
	# their display manager alone.
	exit 0
fi

run_in_target()
{
	if [ "$root" = / ]; then
		"$@"
	else
		"$chroot_tool" "$root" "$@"
	fi
}

run_systemctl()
{
	if [ "$root" = / ]; then
		"$systemctl_tool" "$@"
	else
		"$systemctl_tool" --root="$root" "$@"
	fi
}

if ! run_in_target pacman -Qq plasma-login-manager >/dev/null 2>&1; then
	echo "installing plasma-login-manager" >&2
	run_in_target pacman -S --needed --noconfirm --disable-sandbox \
		plasma-login-manager
fi

if [ ! -e "$root/usr/lib/systemd/system/plasmalogin.service" ]; then
	echo "plasmalogin.service is missing after installing plasma-login-manager" >&2
	exit 1
fi

# SDDM and PLM share the display-manager.service alias.  Remove the stale
# alias before enabling PLM; systemctl will not replace an existing alias.
if [ -L "$root/etc/systemd/system/display-manager.service" ]; then
	rm -f -- "$root/etc/systemd/system/display-manager.service"
fi
run_systemctl enable plasmalogin.service >/dev/null

for package in sddm-kcm sddm; do
	if run_in_target pacman -Qq "$package" >/dev/null 2>&1; then
		run_in_target pacman -R --noconfirm "$package"
	fi
done

echo "Plasma Login Manager is now the active display manager" >&2
