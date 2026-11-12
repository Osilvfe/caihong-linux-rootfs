#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
#
# Prepare and expose a disposable AArch64 build root for device payloads.
# The same root is used for the Arch Linux ARM and Armada platform packages so
# that the binaries in an image and in an incremental update come from one
# build environment.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
command=${1:-}
root=${2:-}
distribution=${3:-}
arch_mirror=${ARCHLINUXARM_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm}
arch_mirror=${arch_mirror%/}
arch_archive=${ARCHLINUXARM_ARCHIVE:-"$project_dir/downloads/ArchLinuxARM-aarch64-latest.tar.gz"}
armada_image=${ARMADA_IMAGE:-ghcr.io/armada-os/armada:stable}
ready_marker=.caihong-build-root-ready

fail()
{
	echo "caihong-build-root: $*" >&2
	exit 1
}

if [[ $command != prepare && $command != cleanup ]]; then
	echo "usage: $0 prepare ROOT DISTRIBUTION" >&2
	echo "       $0 cleanup ROOT" >&2
	exit 2
fi
if [[ -z $root ]]; then
	fail "missing root directory"
fi
case $root in
	/|/boot|/home|/usr|/var) fail "refusing unsafe root directory: $root" ;;
esac
mkdir -p "$root"
root=$(cd -- "$root" && pwd)

for tool in bsdtar mountpoint rsync umount; do
	command -v "$tool" >/dev/null 2>&1 || fail "missing host tool: $tool"
done

mount_api()
{
	[[ -d $root/dev ]] || mkdir -p "$root/dev" "$root/proc" "$root/sys" "$root/run"
	if ! mountpoint -q "$root"; then
		mount --bind "$root" "$root"
		mount --make-private "$root"
	fi
	if [[ ${CAIHONG_ROOTLESS_BUILD_ROOT:-0} != 1 ]]; then
		for api_directory in dev proc sys; do
			if ! mountpoint -q "$root/$api_directory"; then
				mount --bind "/$api_directory" "$root/$api_directory"
				mount --make-private "$root/$api_directory"
			fi
		done
	else
		# A userns cannot bind the host devtmpfs or procfs. Provide only the
		# nodes package builds need; /proc is a fresh pid-namespaced procfs
		# when the caller created a PID namespace.
		if ! mountpoint -q "$root/dev"; then
			mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$root/dev"
			for node in null zero full random urandom tty; do
				touch "$root/dev/$node"
				mount --bind "/dev/$node" "$root/dev/$node"
			done
		fi
		if ! mountpoint -q "$root/proc"; then
			if ! mount -t proc proc "$root/proc" 2>/dev/null; then
				fail "rootless chroot needs a PID namespace for /proc"
			fi
		fi
		if ! mountpoint -q "$root/sys"; then
			mount -t tmpfs -o mode=0555,ro tmpfs "$root/sys" 2>/dev/null || true
		fi
	fi
	if ! mountpoint -q "$root/run"; then
		mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$root/run"
	fi
}

unmount_api()
{
	for api_directory in run sys proc dev; do
		if mountpoint -q "$root/$api_directory"; then
			umount --lazy "$root/$api_directory" || true
		fi
	done
	if mountpoint -q "$root"; then
		umount --lazy "$root" || true
	fi
}

if [[ $command == cleanup ]]; then
	unmount_api
	exit 0
fi

[[ $distribution == archlinuxarm || $distribution == armada ]] || \
	fail "distribution must be archlinuxarm or armada"
if [[ -f $root/$ready_marker ]] && [[ $(<"$root/$ready_marker") == "$distribution" ]]; then
	mount_api
	exit 0
fi

if [[ -n $(find "$root" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit) ]]; then
	fail "build root is not empty and has no matching ready marker: $root"
fi

cleanup_on_error()
{
	status=$?
	unmount_api
	exit "$status"
}
trap cleanup_on_error EXIT HUP INT TERM

case $distribution in
	archlinuxarm)
		command -v curl >/dev/null 2>&1 || fail "missing host tool: curl"
		mkdir -p "$(dirname -- "$arch_archive")"
		if [[ ! -f $arch_archive ]]; then
			temporary="$arch_archive.part"
			rm -f -- "$temporary"
			curl -fL --retry 4 --retry-delay 2 -o "$temporary" \
				"$arch_mirror/os/ArchLinuxARM-aarch64-latest.tar.gz"
			mv -- "$temporary" "$arch_archive"
		fi
		bsdtar -tf "$arch_archive" >/dev/null
		# A rootless namespace can map only its own UID, so restoring the
		# archive's numeric ownership fails for unrelated system accounts.
		# Build roots are disposable and package installation resets ownership
		# for everything that ships in the payload.
		if (( EUID == 0 )) && [[ $(uname -m) == aarch64 || $(uname -m) == arm64 ]]; then
			bsdtar --numeric-owner -xpf "$arch_archive" -C "$root"
		else
			bsdtar --no-same-owner --no-same-permissions -xpf \
				"$arch_archive" -C "$root"
		fi
		mkdir -p "$root/etc/pacman.d"
		printf 'Server = %s\n' \
			"${PACMAN_SERVER:-$arch_mirror/\$arch/\$repo}" \
			> "$root/etc/pacman.d/mirrorlist"
		if ! grep -q '^DisableSandboxFilesystem$' "$root/etc/pacman.conf"; then
			if grep -q '^#DisableSandboxFilesystem$' "$root/etc/pacman.conf"; then
				sed -i 's/^#DisableSandboxFilesystem$/DisableSandboxFilesystem/' \
					"$root/etc/pacman.conf"
			else
				sed -i '/^\[options\]$/a DisableSandboxFilesystem' \
					"$root/etc/pacman.conf"
			fi
		fi
		mount_api
		chroot "$root" /usr/bin/env -i HOME=/root LANG=C PATH=/usr/bin \
			pacman-key --init
		chroot "$root" /usr/bin/env -i HOME=/root LANG=C PATH=/usr/bin \
			pacman-key --populate archlinuxarm
		packages=(
			base-devel
			git
			rsync
			meson
			ninja
			cmake
			extra-cmake-modules
			pkgconf
			libyaml
			libevent
			openssl
			gnutls
			libdrm
			libva
			libjpeg-turbo
			libtiff
			systemd-libs
			glib2
			glib2-devel
			libgudev
			polkit
			upower
			gstreamer
			gst-plugins-base
			python-jinja
			python-ply
			python-yaml
			qt6-base
			qt6-declarative
			qt6-multimedia
			qt6-sensors
			qt6-svg
			qt6-tools
			mesa
			kirigami
			kcoreaddons
			ki18n
			kconfig
			exiv2
			linux-api-headers
		)
		chroot "$root" /usr/bin/env -i HOME=/root LANG=C PATH=/usr/bin \
			pacman -Syu --disable-sandbox --noconfirm --needed "${packages[@]}"
		;;
	armada)
		for tool in skopeo umoci; do
			command -v "$tool" >/dev/null 2>&1 || fail "missing host tool: $tool"
		done
		work_dir=$(mktemp -d "$project_dir/build/caihong-fedora-root.XXXXXX")
		oci_dir="$work_dir/oci"
		bundle="$work_dir/bundle"
		skopeo copy --override-arch arm64 --retry-times 3 \
			"docker://$armada_image" "oci:$oci_dir:armada"
		umoci unpack --image "$oci_dir:armada" "$bundle"
		rsync -aHAX --numeric-ids "$bundle/rootfs/" "$root/"
		rm -rf -- "$work_dir"
		mount_api
		dnf_tool=dnf
		if ! chroot "$root" /usr/bin/env -i PATH=/usr/bin:/usr/sbin \
			command -v dnf >/dev/null 2>&1; then
			dnf_tool=dnf5
		fi
		packages=(
			gcc
			gcc-c++
			cmake
			extra-cmake-modules
			meson
			ninja-build
			pkgconf-pkg-config
			git
			rsync
			python3-jinja2
			python3-ply
			python3-pyyaml
			glib2-devel
			gnutls-devel
			libyaml-devel
			libevent-devel
			libunwind-devel
			openssl-devel
			elfutils-libelf-devel
			libdrm-devel
			libva-devel
			libjpeg-turbo-devel
			libtiff-devel
			alsa-utils
			systemd-devel
			wayland-devel
			mesa-libEGL-devel
			mesa-libGLES-devel
			mesa-libgbm-devel
			gstreamer1-devel
			gstreamer1-plugins-base-devel
			qt6-qtbase-devel
			qt6-qtdeclarative-devel
			qt6-qtmultimedia-devel
			qt6-qtsensors-devel
			qt6-qtsvg-devel
			mesa-libGL-devel
			libgudev-devel
			polkit-devel
			upower-devel
			patch
			kf6-kconfig-devel
			kf6-kcoreaddons-devel
			kf6-ki18n-devel
			kf6-kirigami-devel
			kf6-kirigami-addons-devel
			exiv2-devel
			kernel-headers
		)
		chroot "$root" /usr/bin/env -i HOME=/root LANG=C PATH=/usr/bin:/usr/sbin \
			"$dnf_tool" -y install --setopt=install_weak_deps=False \
			"${packages[@]}"
		;;
esac

printf '%s\n' "$distribution" > "$root/$ready_marker"
trap - EXIT HUP INT TERM
echo "prepared $distribution build root: $root"
