#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
#
# Build power-profiles-daemon with the Caihong Qualcomm profile driver and
# stage it as a pacman package.  This script is meant to run inside the
# Arch Linux ARM rootfs chroot, where the native AArch64 toolchain and the
# GLib/GUdev/Polkit/UPower headers are already installed.
set -Eeuo pipefail
CDPATH=

usage()
{
	echo "usage: $0 SOURCE_DIR PATCH_FILE OUTPUT_DIR [PKGREL]" >&2
	exit 2
}

[[ $# -ge 3 && $# -le 4 ]] || usage

source_dir=${1%/}
patch_file=$2
output_dir=${3%/}
pkgrel=${4:-1}

[[ $pkgrel =~ ^[0-9]+$ ]] || {
	echo "invalid pkgrel: $pkgrel" >&2
	exit 2
}

for path in "$source_dir/meson.build" "$source_dir/src/ppd-driver-cpufreq.c" "$patch_file"; do
	[[ -e $path ]] || {
		echo "missing power-profiles-daemon input: $path" >&2
		exit 1
	}
done

for tool in bsdtar meson ninja patch rsync zstd; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "missing power-profiles-daemon build tool: $tool" >&2
		exit 1
	}
done

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/power-profiles-daemon-caihong.XXXXXX")
cleanup()
{
	rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

rsync -a --exclude=.git --exclude=build "$source_dir/" "$work_dir/source/"
cd "$work_dir/source"

echo "applying the Caihong Qualcomm profile driver patch" >&2
patch -Np1 --batch -i "$patch_file" >&2

echo "building power-profiles-daemon" >&2
meson setup "$work_dir/build" . \
	--buildtype=release \
	--prefix=/usr \
	--libexecdir=lib \
	-Dtests=false \
	-Dgtk_doc=false >&2
meson compile -C "$work_dir/build" >&2

stage="$work_dir/stage"
DESTDIR="$stage" meson install -C "$work_dir/build" --no-rebuild >&2

install -D -m 0644 COPYING \
	"$stage/usr/share/licenses/power-profiles-daemon-caihong/COPYING"

# Fail closed if the packaged daemon did not actually pick up the driver.
grep -aq 'qcom_cpufreq' "$stage/usr/lib/power-profiles-daemon" || {
	echo "power-profiles-daemon was built without the qcom_cpufreq driver" >&2
	exit 1
}

pkgver=$(sed -n "s/^[[:space:]]*version:[[:space:]]*'\([^']*\)'.*/\1/p" meson.build |
	head -n 1)
[[ -n $pkgver ]] || {
	echo "could not determine the power-profiles-daemon version" >&2
	exit 1
}

package_name="power-profiles-daemon-caihong-$pkgver-$pkgrel-aarch64.pkg.tar.zst"
output="$output_dir/$package_name"
installed_size=$(du -sb "$stage" | awk '{ print $1 }')
builddate=${SOURCE_DATE_EPOCH:-$(date +%s)}

cat > "$stage/.PKGINFO" <<EOF
pkgname = power-profiles-daemon-caihong
pkgbase = power-profiles-daemon-caihong
pkgver = $pkgver-$pkgrel
pkgdesc = Power profiles daemon with a Qualcomm cpufreq-hw and Adreno devfreq driver
url = https://gitlab.freedesktop.org/upower/power-profiles-daemon
builddate = $builddate
packager = Caihong rootfs build
size = $installed_size
arch = aarch64
license = GPL-3.0-only
depend = gcc-libs
depend = glib2
depend = glibc
depend = libgudev
depend = polkit
depend = upower
optdepend = python-gobject: for powerprofilesctl
provides = power-profiles-daemon=$pkgver
conflict = power-profiles-daemon
replaces = power-profiles-daemon
EOF

mkdir -p "$output_dir"
temporary="$output.new"
rm -f -- "$temporary"
bsdtar --uid 0 --gid 0 --uname root --gname root -cf - \
	-C "$stage" .PKGINFO usr |
	zstd -T0 -15 -o "$temporary"
mv -- "$temporary" "$output"

bsdtar -tf "$output" >/dev/null
pacman -Qip "$output" >/dev/null
printf '%s\n' "$package_name" > "$output_dir/POWER_PROFILES_DAEMON_PACKAGE"
printf '%s\n' "$package_name"
