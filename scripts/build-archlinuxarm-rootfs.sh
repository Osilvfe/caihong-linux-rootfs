#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
target=${1:-}
archive=${2:-"$project_dir/downloads/ArchLinuxARM-aarch64-latest.tar.gz"}
mirror=${ARCHLINUXARM_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm}
mirror=${mirror%/}
url=${ROOTFS_BASE_URL:-${ARCHLINUXARM_URL:-$mirror/os/ArchLinuxARM-aarch64-latest.tar.gz}}
archive_sha256=${ROOTFS_ARCHIVE_SHA256:-}
distribution_name=${ROOTFS_DISTRIBUTION_NAME:-Arch Linux ARM}
pacman_server=${PACMAN_SERVER:-$mirror/\$arch/\$repo}
root_spec=${ROOT_SPEC:-PARTLABEL=linux}
root_fstype=${ROOT_FSTYPE:-ext4}
module_tree=${MODULE_TREE:-"$project_dir/modules-current"}
install_kernel_modules=${INSTALL_KERNEL_MODULES:-1}

if [ -z "$target" ]; then
	echo "usage: sudo $0 /mounted/archroot [rootfs.tar.gz]" >&2
	exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "run as root so ownership, ACLs and xattrs are preserved" >&2
	exit 1
fi

for tool in bsdtar curl findmnt mountpoint blkid grep rsync sha256sum; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "missing host tool: $tool" >&2
		exit 1
	fi
done

if [ "$install_kernel_modules" != 0 ] && [ "$install_kernel_modules" != 1 ]; then
	echo "INSTALL_KERNEL_MODULES must be 0 or 1" >&2
	exit 1
fi
if [ "$install_kernel_modules" = 1 ]; then
	command -v depmod >/dev/null 2>&1 || {
		echo "missing host tool: depmod" >&2
		exit 1
	}
fi

case "$url" in
	http://*|https://*) ;;
	*)
		echo "ROOTFS_BASE_URL must be an HTTP(S) URL: $url" >&2
		exit 1
		;;
esac
case "$pacman_server" in
	http://*|https://*) ;;
	*)
		echo "PACMAN_SERVER must be an HTTP(S) URL template: $pacman_server" >&2
		exit 1
		;;
esac

if [ ! -d "$target" ]; then
	echo "target directory does not exist: $target" >&2
	exit 1
fi

target=$(cd -- "$target" && pwd)
case "$target" in
	/|/boot|/home|/usr|/var)
		echo "refusing unsafe target: $target" >&2
		exit 1
		;;
esac

if [ "${ALLOW_DIRECTORY:-0}" != 1 ] && ! mountpoint -q "$target"; then
	echo "target is not a mount point: $target" >&2
	echo "mount the prepared root partition first, or set ALLOW_DIRECTORY=1 for staging" >&2
	exit 1
fi

existing=$(find "$target" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit)
if [ -n "$existing" ] && [ "${FORCE:-0}" != 1 ]; then
	echo "target is not empty: $target (set FORCE=1 to overlay deliberately)" >&2
	exit 1
fi

if mountpoint -q "$target"; then
	source_dev=$(findmnt -n -o SOURCE --target "$target")
	case "$root_spec" in
		LABEL=*)
			expected=${root_spec#LABEL=}
			actual=$(blkid -s LABEL -o value "$source_dev" 2>/dev/null || true)
			if [ "$actual" != "$expected" ] && [ "${SKIP_ROOT_CHECK:-0}" != 1 ]; then
				echo "$source_dev has label '$actual', expected '$expected'" >&2
				echo "for ext4: sudo e2label $source_dev $expected" >&2
				exit 1
			fi
			;;
	esac
fi

mkdir -p "$(dirname -- "$archive")"
if [ ! -f "$archive" ]; then
	temporary="$archive.part"
	rm -f -- "$temporary"
	echo "downloading $url"
	curl -fL --retry 4 --retry-delay 2 -o "$temporary" "$url"
	mv -- "$temporary" "$archive"
fi

echo "validating $archive"
if [ -n "$archive_sha256" ]; then
	printf '%s  %s\n' "$archive_sha256" "$archive" | sha256sum -c -
fi
bsdtar -tf "$archive" >/dev/null

echo "extracting $distribution_name into $target"
bsdtar --numeric-owner -xpf "$archive" -C "$target"

mkdir -p "$target/etc/pacman.d"
{
	printf '# Caihong %s package snapshot\n' "$distribution_name"
	printf 'Server = %s\n' "$pacman_server"
} > "$target/etc/pacman.d/mirrorlist"
echo "configured pacman server: $pacman_server"

# The current Caihong kernel has seccomp support, but CONFIG_SECURITY_LANDLOCK
# is disabled.  Keep pacman's syscall sandbox and downloader user separation,
# while avoiding a guaranteed Landlock failure on the device.
if ! grep -q '^DisableSandboxFilesystem$' "$target/etc/pacman.conf"; then
	if grep -q '^#DisableSandboxFilesystem$' "$target/etc/pacman.conf"; then
		sed -i 's/^#DisableSandboxFilesystem$/DisableSandboxFilesystem/' \
			"$target/etc/pacman.conf"
	else
		sed -i '/^\[options\]$/a DisableSandboxFilesystem' \
			"$target/etc/pacman.conf"
	fi
fi

if [ "$install_kernel_modules" = 1 ]; then
	echo "installing matching Caihong kernel modules"
	"$project_dir/scripts/install-caihong-modules.sh" "$module_tree" "$target"
else
	echo "deferring kernel module installation to the release packager"
	rm -rf -- "$target/usr/lib/modules"
fi

# Remove ACM diagnostics from older generated roots used as an input archive.
rm -f -- \
	"$target/usr/local/sbin/caihong-usb-gadget" \
	"$target/etc/systemd/system/caihong-usb-gadget.service" \
	"$target/etc/systemd/system/sysinit.target.wants/caihong-usb-gadget.service" \
	"$target/etc/systemd/system/multi-user.target.wants/caihong-usb-gadget.service" \
	"$target/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"

printf '%s\n' caihong > "$target/etc/hostname"
printf '%s / %s rw,noatime 0 1\n' "$root_spec" "$root_fstype" > "$target/etc/fstab"
: > "$target/etc/machine-id"

if [ "${INCLUDE_BOOT_ARTIFACTS:-0}" = 1 ]; then
	install -D -m 0644 "$project_dir/linux/out/arch/arm64/boot/Image" \
		"$target/boot/caihong/Image"
	install -D -m 0644 \
		"$project_dir/linux/out/arch/arm64/boot/dts/qcom/sm8650-oneplus-caihong.dtb" \
		"$target/boot/caihong/sm8650-oneplus-caihong.dtb"
fi

if [ "${CHROOT_INIT:-0}" = 1 ]; then
	required_tools='arch-chroot'
	case $(uname -m) in
		aarch64|arm64) ;;
		*) required_tools="$required_tools qemu-aarch64-static" ;;
	esac
	for tool in $required_tools; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			echo "CHROOT_INIT=1 requires: $tool" >&2
			exit 1
		fi
	done
	echo "initializing Arch Linux ARM pacman keys"
	arch-chroot "$target" /usr/bin/pacman-key --init
	arch-chroot "$target" /usr/bin/pacman-key --populate archlinuxarm
fi

sync
echo "$distribution_name rootfs is ready at $target"
echo "root spec: $root_spec ($root_fstype)"
echo "default upstream credentials: root/root and alarm/alarm"
