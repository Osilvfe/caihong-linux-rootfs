#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
output=${1:-"$project_dir/archlinuxarm-caihong-rootfs.img"}
source_archive=${2:-"$project_dir/downloads/ArchLinuxARM-aarch64-latest.tar.gz"}
module_tree=${MODULE_TREE:-"$project_dir/modules-current"}
mirror=${ARCHLINUXARM_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm}
mirror=${mirror%/}
package_cache=${PACKAGE_CACHE:-"$project_dir/build/pacman-cache"}
ssc_bundle=${SSC_BUNDLE:-"$project_dir/firmware-assets/caihong-ssc"}
npu_bundle=${NPU_BUNDLE:-"$project_dir/firmware-assets/caihong-npu"}
platform_package=${CAIHONG_PLATFORM_PACKAGE:-}
npu_package=${CAIHONG_NPU_PACKAGE:-}
output_format=${OUTPUT_FORMAT:-ext4}
image_size_gib=${IMAGE_SIZE_GIB:-}
image_min_free_mib=${IMAGE_MIN_FREE_MIB:-2048}
image_slack_percent=${IMAGE_SLACK_PERCENT:-25}
sparse_image=${SPARSE_IMAGE:-1}
image_populator=${IMAGE_POPULATOR:-mount}
zstd_level=${ZSTD_LEVEL:-10}
chroot_tool=${CHROOT_TOOL:-arch-chroot}
use_proxy=${USE_PROXY:-1}
case $(uname -m) in
	aarch64|arm64) native_aarch64=1 ;;
	*) native_aarch64=0 ;;
esac
cpu_count=$(nproc)
if (( cpu_count > 1 )); then
	zstd_threads_default=$((cpu_count - 1))
else
	zstd_threads_default=1
fi
zstd_threads=${ZSTD_THREADS:-$zstd_threads_default}

if [[ ! -d $module_tree/lib/modules ]]; then
	echo "module tree not found: $module_tree/lib/modules" >&2
	exit 1
fi
module_releases=()
for candidate in "$module_tree"/lib/modules/*; do
	[[ -d $candidate ]] || continue
	module_releases+=("${candidate##*/}")
done
if (( ${#module_releases[@]} != 1 )); then
	echo "expected exactly one kernel release below $module_tree/lib/modules" >&2
	exit 1
fi
kernel_release=${module_releases[0]}
kernel_package=${KERNEL_PACKAGE:-}
if [[ -z $kernel_package && -f $project_dir/release/LINUX_CAIHONG_PACKAGE ]]; then
	kernel_package=$project_dir/release/$(<"$project_dir/release/LINUX_CAIHONG_PACKAGE")
fi
if [[ ! -f $kernel_package ]]; then
	echo "linux-caihong package not found: ${kernel_package:-unset}" >&2
	exit 1
fi
kernel_package=$(cd -- "$(dirname -- "$kernel_package")" && pwd)/${kernel_package##*/}

if [[ ! -d $ssc_bundle ]]; then
	echo "missing release SSC bundle: $ssc_bundle" >&2
	exit 1
fi
ssc_bundle=$(cd -- "$ssc_bundle" && pwd)
if [[ ! -d $npu_bundle ]]; then
	echo "missing release NPU bundle: $npu_bundle" >&2
	exit 1
fi
npu_bundle=$(cd -- "$npu_bundle" && pwd)
if [[ -z $platform_package && -f $project_dir/release/CAIHONG_PLATFORM_PACKAGE ]]; then
	platform_package=$project_dir/release/$(<"$project_dir/release/CAIHONG_PLATFORM_PACKAGE")
fi
if [[ -z $npu_package && -f $project_dir/release/CAIHONG_NPU_PACKAGE ]]; then
	npu_package=$project_dir/release/$(<"$project_dir/release/CAIHONG_NPU_PACKAGE")
fi
if [[ -n $platform_package ]]; then
	platform_package=$(cd -- "$(dirname -- "$platform_package")" && pwd)/${platform_package##*/}
	[[ -f $platform_package ]] || {
		echo "platform package not found: $platform_package" >&2
		exit 1
	}
fi
if [[ -n $npu_package ]]; then
	npu_package=$(cd -- "$(dirname -- "$npu_package")" && pwd)/${npu_package##*/}
	[[ -f $npu_package ]] || {
		echo "NPU package not found: $npu_package" >&2
		exit 1
	}
fi

# This is intentionally a native AArch64 development environment.  base-devel
# provides GCC, binutils, make, pkgconf and the normal Arch package build tools;
# the remaining packages cover common Linux/kernel builds.
packages=(
	base-devel
	git
	bc
	bison
	flex
	cpio
	dtc
	libelf
	libbsd
	libyaml
	ncurses
	openssl
	pahole
	perl
	python
	python-gobject
	python-jinja
	python-ply
	python-yaml
	rsync
	sudo
	cmake
	extra-cmake-modules
	meson
	ninja
	qt6-tools
	networkmanager
	wpa_supplicant
	hostapd
	dnsmasq
	nftables
	iw
	bluez
	bluez-utils
	openssh
	android-tools
	usbutils
	pciutils
	i2c-tools
	ethtool
	evtest
	strace
	lsof
	tcpdump
	plasma-meta
	sddm
	sddm-kcm
	konsole
	dolphin
	mesa
	mesa-utils
	vulkan-freedreno
	vulkan-tools
	xorg-server
	xorg-xwayland
	pipewire
	pipewire-pulse
	wireplumber
	alsa-utils
	v4l-utils
	iio-sensor-proxy
	libssc
	libcamera
	libcamera-ipa
	libcamera-tools
	gst-plugin-libcamera
	plasma-camera
	krita
	firefox
	power-profiles-daemon
	upower
	xdg-user-dirs
	noto-fonts
	noto-fonts-cjk
	e2fsprogs
)

# The generic rootfs ships a distribution kernel.  Caihong boots the custom
# Image and DTB from the Android boot image, so these packages and their /boot
# payloads/module tree are both unnecessary and potentially confusing.
unwanted_boot_packages=(
	linux-aarch64
	linux-aarch64-headers
	linux-firmware
	linux-firmware-amd
	linux-firmware-amdgpu
	linux-firmware-atheros
	linux-firmware-broadcom
	linux-firmware-cirrus
	linux-firmware-intel
	linux-firmware-mediatek
	linux-firmware-nvidia
	linux-firmware-other
	linux-firmware-radeon
	linux-firmware-realtek
	linux-firmware-ti
	linux-firmware-whence
)

if [[ -n ${EXTRA_PACKAGES:-} ]]; then
	# EXTRA_PACKAGES is a whitespace-separated list of additional Arch packages.
	read -r -a extra_packages <<< "$EXTRA_PACKAGES"
	packages+=("${extra_packages[@]}")
fi

if [[ $use_proxy != 0 && $use_proxy != 1 ]]; then
	echo "USE_PROXY must be 0 or 1" >&2
	exit 1
fi

if (( EUID != 0 )); then
	echo "run as root so ownership, ACLs and xattrs are preserved" >&2
	exit 1
fi

required_tools=("$chroot_tool" bsdtar curl mount mountpoint nproc rsync sha256sum umount)
if (( ! native_aarch64 )); then
	required_tools+=(qemu-aarch64-static)
fi
for tool in "${required_tools[@]}"; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "missing host tool: $tool" >&2
		exit 1
	fi
done

case "$output_format" in
	ext4)
	for tool in blkid du e2fsck img2simg mkfs.ext4 rsync truncate; do
			if ! command -v "$tool" >/dev/null 2>&1; then
				echo "missing host tool: $tool" >&2
				exit 1
			fi
	done
	case "$image_populator" in
		mount) ;;
		mke2fs) ;;
		e2fsdroid)
			if ! command -v e2fsdroid >/dev/null 2>&1; then
				echo "missing host tool: e2fsdroid" >&2
				exit 1
			fi
			;;
		*)
			echo "IMAGE_POPULATOR must be mount, mke2fs or e2fsdroid" >&2
			exit 1
			;;
	esac
	;;
	tar)
		if ! command -v zstd >/dev/null 2>&1; then
			echo "missing host tool: zstd" >&2
			exit 1
		fi
		case "$zstd_level" in
			''|*[!0-9]*)
				echo "ZSTD_LEVEL must be an integer from 1 to 19" >&2
				exit 1
				;;
		esac
		if (( zstd_level < 1 || zstd_level > 19 )); then
			echo "ZSTD_LEVEL must be an integer from 1 to 19" >&2
			exit 1
		fi
		case "$zstd_threads" in
			''|*[!0-9]*|0)
				echo "ZSTD_THREADS must be a positive integer" >&2
				exit 1
				;;
		esac
		;;
	*)
		echo "OUTPUT_FORMAT must be ext4 or tar" >&2
		exit 1
		;;
esac

if [[ $output_format == ext4 ]]; then
	for value_name in image_min_free_mib image_slack_percent; do
		value=${!value_name}
		case "$value" in
			''|*[!0-9]*)
				echo "$value_name must be a non-negative integer" >&2
				exit 1
				;;
		esac
	done
	if [[ -n $image_size_gib ]]; then
		case "$image_size_gib" in
			*[!0-9]*|0)
				echo "IMAGE_SIZE_GIB must be a positive integer" >&2
				exit 1
				;;
		esac
	fi
	if [[ $sparse_image != 0 && $sparse_image != 1 ]]; then
		echo "SPARSE_IMAGE must be 0 or 1" >&2
		exit 1
	fi
fi

output_dir=$(dirname -- "$output")
mkdir -p "$output_dir" "$project_dir/build" "$project_dir/downloads"
output_dir=$(cd -- "$output_dir" && pwd)
output="$output_dir/$(basename -- "$output")"
temporary="$output.part"

if [[ -e $output || -e $temporary ]]; then
	if [[ ${FORCE:-0} != 1 ]]; then
		echo "refusing to overwrite existing output: $output" >&2
		echo "set FORCE=1 to replace it, or choose another output path" >&2
		exit 1
	fi
	rm -f -- "$output" "$temporary"
fi

work_dir=$(mktemp -d "$project_dir/build/archroot-package.XXXXXX")
rootfs="$work_dir/rootfs"
image_mount="$work_dir/image-mount"
mkdir -p "$rootfs"
rootfs_mounted=0
image_mounted=0

unmount_image()
{
	if (( image_mounted )) && mountpoint -q "$image_mount"; then
		if ! umount "$image_mount"; then
			return 1
		fi
	fi
	image_mounted=0
}

unmount_rootfs()
{
	if (( rootfs_mounted )); then
		# Only these private, non-recursive API mounts are created below. Detach
		# them explicitly before the self-bind so cleanup never descends into a
		# mounted host API filesystem.
		for api_directory in run sys proc dev; do
			if mountpoint -q "$rootfs/$api_directory"; then
				umount --lazy "$rootfs/$api_directory" || return 1
			fi
		done
		if mountpoint -q "$rootfs"; then
			umount --lazy "$rootfs" || return 1
		fi
		for api_directory in run sys proc dev; do
			mountpoint -q "$rootfs/$api_directory" && return 1
		done
		mountpoint -q "$rootfs" && return 1
	fi
	rootfs_mounted=0
}

save_package_cache()
{
	local source="$rootfs/var/cache/pacman/pkg"
	[[ -d $source ]] || return 0
	mkdir -p "$package_cache"
	rsync -a --include='*.pkg.tar.*' --exclude='*' "$source/" "$package_cache/"
}

cleanup()
{
	status=$?
	trap - EXIT HUP INT TERM
	if ! save_package_cache; then
		echo "warning: failed to preserve the pacman package cache" >&2
	fi
	if ! unmount_image; then
		echo "failed to unmount temporary ext4 image: $image_mount" >&2
		echo "temporary tree was preserved for manual recovery" >&2
		rm -f -- "$temporary"
		exit 1
	fi
	if ! unmount_rootfs; then
		echo "failed to unmount temporary rootfs: $rootfs" >&2
		echo "temporary tree was preserved for manual recovery" >&2
		rm -f -- "$temporary"
		exit 1
	fi
	rm -f -- "$temporary"
	rm -rf -- "$work_dir"
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

echo "populating the base Arch Linux ARM rootfs"
ALLOW_DIRECTORY=1 \
	ARCHLINUXARM_MIRROR="$mirror" \
	ROOT_SPEC=PARTLABEL=linux \
	ROOT_FSTYPE=ext4 \
	MODULE_TREE="$module_tree" \
	SSC_BUNDLE="$ssc_bundle" \
	INSTALL_KERNEL_MODULES=0 \
	INCLUDE_WIFI=1 \
	"$project_dir/scripts/build-archlinuxarm-rootfs.sh" \
	"$rootfs" "$source_archive"

# Board-specific policy and first-boot services live outside the generic
# Arch Linux ARM archive so rebuilt images remain reproducible.
rsync -aHAX --numeric-ids --chown=0:0 \
	"$project_dir/rootfs/archlinuxarm/" "$rootfs/"
if [[ $(stat -c '%u:%g' "$rootfs") != 0:0 || \
	$(stat -c '%u:%g' "$rootfs/etc") != 0:0 ]]; then
	echo "board overlay changed rootfs directory ownership" >&2
	exit 1
fi

# Keep the rootfs's resolver configuration for the final archive, but use the
# host resolver while pacman runs in the host network namespace.
resolver_saved=0
if [[ -e $rootfs/etc/resolv.conf || -L $rootfs/etc/resolv.conf ]]; then
	cp -a --no-dereference "$rootfs/etc/resolv.conf" "$work_dir/resolv.conf.original"
	resolver_saved=1
fi
rm -f -- "$rootfs/etc/resolv.conf"
cp -L -- /etc/resolv.conf "$rootfs/etc/resolv.conf"

# A self bind mount anchors the API filesystems below the temporary rootfs.
# Use non-recursive binds: package construction needs the main /dev, /proc and
# /sys filesystems, but importing host submounts such as binfmt_misc makes the
# temporary tree difficult to unmount reliably.
mount --bind "$rootfs" "$rootfs"
rootfs_mounted=1
mount --make-private "$rootfs"
if [[ $chroot_tool == chroot ]]; then
	for api_directory in dev proc sys; do
		mount --bind "/$api_directory" "$rootfs/$api_directory"
		mount --make-private "$rootfs/$api_directory"
	done
	# Do not import the user's /run tree into a rootless build. In particular,
	# xdg-document-portal's FUSE mount cannot be recursively unmounted from the
	# user namespace. A private runtime tmpfs is sufficient for package hooks.
	mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$rootfs/run"
fi

# AArch64 hosts execute the rootfs directly. Other architectures need a static
# user-mode interpreter registered with binfmt_misc.
if (( ! native_aarch64 )); then
	install -D -m 0755 "$(command -v qemu-aarch64-static)" \
		"$rootfs/usr/bin/qemu-aarch64-static"
fi
if ! "$chroot_tool" "$rootfs" /usr/bin/true; then
	if (( native_aarch64 )); then
		echo "unable to execute the AArch64 rootfs natively" >&2
	else
		echo "AArch64 binfmt is not active" >&2
		echo "install qemu-user-static-binfmt, then restart systemd-binfmt" >&2
	fi
	exit 1
fi

chroot_env=(/usr/bin/env -i HOME=/root LANG=C
	PATH=/usr/local/sbin:/usr/local/bin:/usr/bin SYSTEMD_OFFLINE=1)
if [[ $use_proxy == 1 ]]; then
	for variable in http_proxy https_proxy ftp_proxy all_proxy no_proxy \
		HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY; do
		if [[ -n ${!variable:-} ]]; then
			chroot_env+=("$variable=${!variable}")
		fi
	done
fi

echo "initializing the Arch Linux ARM package keyring"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" pacman-key --init
"$chroot_tool" "$rootfs" "${chroot_env[@]}" pacman-key --populate archlinuxarm

echo "removing boot-owned kernel and generic firmware packages"
for package in "${unwanted_boot_packages[@]}"; do
	if "$chroot_tool" "$rootfs" "${chroot_env[@]}" \
		pacman -Qq "$package" >/dev/null 2>&1; then
		"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
			pacman -R --noconfirm "$package"
	fi
done

# No kernel or DTB is consumed from this filesystem.  This also removes copies
# left behind when an older generated rootfs archive is used as the input.
rm -rf -- "$rootfs/boot/caihong"

echo "installing the native AArch64 build environment"
if [[ -d $package_cache ]]; then
	rsync -a --include='*.pkg.tar.*' --exclude='*' \
		"$package_cache/" "$rootfs/var/cache/pacman/pkg/"
fi
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	pacman -Syu --disable-sandbox --noconfirm --needed \
	--overwrite 'usr/share/alsa/ucm2/conf.d/sm8650/SM8650-MTP.conf' \
	"${packages[@]}"
save_package_cache
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	pacman -Scc --disable-sandbox --noconfirm

# Pacman owns the generic SM8650 UCM path above. Reapply the board overlay so
# the packaged rootfs retains the Caihong routing and all other board policy.
echo "reapplying the Caihong rootfs overlay after package installation"
rsync -aHAX --numeric-ids --chown=0:0 \
	"$project_dir/rootfs/archlinuxarm/" "$rootfs/"
rm -f -- "$rootfs/etc/alsa/state-daemon.conf"

echo "enabling NetworkManager, Bluetooth and the Plasma display manager"
# These operations only create/remove symlinks. Running the host systemctl in
# offline --root mode avoids D-Bus and chroot-detection failures under qemu in
# an unprivileged user namespace.
systemctl --root="$rootfs" disable dhcpcd.service 2>/dev/null || true
systemctl --root="$rootfs" disable \
	systemd-networkd.service systemd-networkd-wait-online.service \
	2>/dev/null || true
systemctl --root="$rootfs" disable hostapd.service dnsmasq.service \
	2>/dev/null || true
systemctl --root="$rootfs" enable \
	NetworkManager.service bluetooth.service power-profiles-daemon.service \
	sshd.service sddm.service
systemctl --root="$rootfs" set-default graphical.target
systemctl --root="$rootfs" enable caihong-grow-rootfs.service
systemctl --root="$rootfs" enable caihong-fix-kwin-brightness.service
systemctl --root="$rootfs" enable caihong-clean-pogo-kde.service
systemctl --root="$rootfs" enable caihong-bluetooth-autostart.service
systemctl --root="$rootfs" enable caihong-adbd.service
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	usermod -aG audio,input,video,wheel alarm
chmod 0440 "$rootfs/etc/sudoers.d/10-alarm"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" visudo -cf /etc/sudoers

# The Pogo keyboard has no backlight.  Remove the generic PowerDevil action so
# Plasma cannot present a non-functional keyboard-brightness control even if
# an old user shortcut file or a package update leaves the plugin enabled.
rm -f -- \
	"$rootfs/usr/lib/qt6/plugins/powerdevil/action/powerdevil_keyboardbrightnesscontrolaction.so"

echo "configuring the English (United States) locale and Asia/Shanghai timezone"
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$rootfs/etc/locale.gen"
if ! grep -qx 'en_US.UTF-8 UTF-8' "$rootfs/etc/locale.gen"; then
	printf 'en_US.UTF-8 UTF-8\n' >> "$rootfs/etc/locale.gen"
fi
"$chroot_tool" "$rootfs" "${chroot_env[@]}" locale-gen
printf 'LANG=en_US.UTF-8\n' > "$rootfs/etc/locale.conf"
ln -sfn /usr/share/zoneinfo/Asia/Shanghai "$rootfs/etc/localtime"

for package in "${unwanted_boot_packages[@]}"; do
	if "$chroot_tool" "$rootfs" "${chroot_env[@]}" \
		pacman -Qq "$package" >/dev/null 2>&1; then
		echo "unwanted distribution kernel package was reinstalled: $package" >&2
		exit 1
	fi
done

# These distribution packages own the same paths as the Caihong build below.
# Keep system upgrades from silently replacing the GPU coherency fixes and
# board-specific IPA tuning before an updated Caihong build is available.
libcamera_ignore='IgnorePkg = libcamera libcamera-ipa libcamera-tools gst-plugin-libcamera plasma-camera'
pacman_conf="$rootfs/etc/pacman.conf"
pacman_conf_new="$pacman_conf.caihong"
awk -v directive="$libcamera_ignore" '
	$0 == "# Managed by the Caihong rootfs builder." || $0 == directive { next }
	$0 == "[options]" {
		print
		print "# Managed by the Caihong rootfs builder."
		print directive
		inserted = 1
		next
	}
	{ print }
	END { if (!inserted) exit 1 }
' "$pacman_conf" > "$pacman_conf_new"
chmod --reference="$pacman_conf" "$pacman_conf_new"
chown --reference="$pacman_conf" "$pacman_conf_new"
mv -f -- "$pacman_conf_new" "$pacman_conf"

echo "building and installing the Caihong libcamera stack"
CHROOT_TOOL="$chroot_tool" \
	"$project_dir/scripts/install-caihong-libcamera-rootfs.sh" "$rootfs"

echo "building and installing Caihong Plasma Camera"
CHROOT_TOOL="$chroot_tool" \
	"$project_dir/scripts/install-caihong-plasma-camera-rootfs.sh" "$rootfs"

echo "building the Caihong NVRAM MAC reader"
install -D -m 0644 "$project_dir/tools/caihong-nvram-mac.c" \
	"$rootfs/tmp/caihong-nvram-mac.c"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	gcc -O2 -Wall -Wextra -Werror \
	-o /usr/local/libexec/caihong-nvram-mac \
	/tmp/caihong-nvram-mac.c -lcrypto
rm -f -- "$rootfs/tmp/caihong-nvram-mac.c"

echo "building the Caihong NPU capability probe"
install -D -m 0644 "$project_dir/tools/caihong-npu-info.c" \
	"$rootfs/tmp/caihong-npu-info.c"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	gcc -O2 -Wall -Wextra -Werror \
	-o /usr/local/sbin/caihong-npu-info \
	/tmp/caihong-npu-info.c -ldl
rm -f -- "$rootfs/tmp/caihong-npu-info.c"

echo "installing packaged Caihong update payloads"
install -d -m 0755 "$rootfs/tmp/caihong-packages"
if [[ -n $platform_package ]]; then
	install -m 0644 "$platform_package" \
		"$rootfs/tmp/caihong-packages/$(<"$project_dir/release/CAIHONG_PLATFORM_PACKAGE")"
fi
if [[ -n $npu_package ]]; then
	install -m 0644 "$npu_package" \
		"$rootfs/tmp/caihong-packages/$(<"$project_dir/release/CAIHONG_NPU_PACKAGE")"
fi
if [[ -n $platform_package ]]; then
	CAIHONG_PLATFORM_ROOT="$rootfs" \
	"$project_dir/packaging/caihong-platform/install-caihong-platform" \
		"$rootfs/tmp/caihong-packages/$(<"$project_dir/release/CAIHONG_PLATFORM_PACKAGE")"
fi
if [[ -n $npu_package ]]; then
	CAIHONG_PLATFORM_ROOT="$rootfs" \
	"$project_dir/packaging/caihong-platform/install-caihong-platform" \
		"$rootfs/tmp/caihong-packages/$(<"$project_dir/release/CAIHONG_NPU_PACKAGE")"
fi

echo "building and installing qbootctl"
if [[ ! -f $project_dir/external/qbootctl/meson.build ]]; then
	echo "missing qbootctl source; run scripts/checkout-dependencies.sh" >&2
	exit 1
fi
rsync -a --exclude=.git --exclude=build \
	"$project_dir/external/qbootctl/" "$rootfs/tmp/qbootctl/"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	meson setup /tmp/qbootctl/build /tmp/qbootctl \
	--buildtype=release --prefix=/usr/local --bindir=sbin
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	meson compile -C /tmp/qbootctl/build
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	meson install -C /tmp/qbootctl/build --no-rebuild
rm -rf -- "$rootfs/tmp/qbootctl"

echo "installing Caihong-only runtime firmware"
rm -rf -- "$rootfs/usr/lib/firmware"
mkdir -p "$rootfs/usr/lib/firmware"
(cd "$project_dir/firmware" && sha256sum -c SHA256SUMS)
rsync -a --exclude=SOURCE.md --exclude=SHA256SUMS \
	"$project_dir/firmware/." "$rootfs/usr/lib/firmware/"
"$project_dir/scripts/build-caihong-audioreach-topology.sh" \
	"$rootfs/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin"

# Register the kernel and its dependency-closed module tree with pacman.  The
# package script is explicitly barred from touching host block devices while
# this offline rootfs is constructed.
echo "installing linux-caihong pacman package"
install -m 0644 "$kernel_package" "$rootfs/tmp/linux-caihong.pkg.tar.zst"
rm -rf -- "$rootfs/usr/lib/modules"
install -d -m 0755 "$rootfs/run/caihong"
touch "$rootfs/run/caihong/offline-rootfs-build"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	env CAIHONG_SKIP_BOOT_FLASH=1 \
	pacman -U --noconfirm /tmp/linux-caihong.pkg.tar.zst
rm -f -- "$rootfs/run/caihong/offline-rootfs-build"
if ! "$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	pacman -Qq linux-caihong >/dev/null; then
	echo "linux-caihong was not registered in the rootfs package database" >&2
	exit 1
fi
rm -f -- "$rootfs/tmp/linux-caihong.pkg.tar.zst"
rm -rf -- "$rootfs/tmp/caihong-packages"
rm -rf -- "$rootfs/usr/lib/firmware"
install -d -m 0755 "$rootfs/usr/lib/firmware"
rsync -a --exclude=SOURCE.md --exclude=SHA256SUMS \
	"$project_dir/firmware/." "$rootfs/usr/lib/firmware/"
"$project_dir/scripts/build-caihong-audioreach-topology.sh" \
	"$rootfs/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin"
"$project_dir/scripts/install-caihong-adbd.sh" "$rootfs"

rm -f -- "$rootfs/usr/bin/qemu-aarch64-static"
rm -f -- "$rootfs/etc/resolv.conf"
if (( resolver_saved )); then
	cp -a --no-dereference "$work_dir/resolv.conf.original" "$rootfs/etc/resolv.conf"
fi
unmount_rootfs

"$project_dir/scripts/verify-archlinuxarm-rootfs.sh" "$rootfs"

{
	printf 'device=caihong\n'
	printf 'architecture=aarch64\n'
	printf 'boot_roots=PARTLABEL=linux,PARTLABEL=userdata\n'
	printf 'boot_kernel=android-boot-v2-direct-root\n'
	printf 'package_mirror=%s\n' "$mirror"
	printf 'kernel_release=%s\n' "$kernel_release"
	printf 'kernel_package=%s\n' "${kernel_package##*/}"
	printf 'ssc_bundle_version=%s\n' "$(head -n 1 "$ssc_bundle/VERSION")"
	if [[ -f $ssc_bundle/SHA256SUMS ]]; then
		printf 'ssc_manifest_sha256=%s\n' \
			"$(sha256sum "$ssc_bundle/SHA256SUMS" | awk '{ print $1 }')"
	fi
	printf 'packages='
	printf '%s ' "${packages[@]}"
	printf '\n'
} > "$rootfs/etc/caihong-rootfs-build-info"
chmod 0644 "$rootfs/etc/caihong-rootfs-build-info"
: > "$rootfs/etc/machine-id"

echo "creating $output"
if [[ $output_format == tar ]]; then
	bsdtar --acls --xattrs -cpf - -C "$rootfs" . \
		| zstd -T"$zstd_threads" "-$zstd_level" -o "$temporary"
	zstd -t "$temporary"
	bsdtar -tf "$temporary" >/dev/null
else
	used_bytes=$(du -sx --block-size=1 "$rootfs" | awk 'NR == 1 { print $1 }')
	percent_free=$((used_bytes * image_slack_percent / 100))
	minimum_free=$((image_min_free_mib * 1024 * 1024))
	if (( percent_free < minimum_free )); then
		free_bytes=$minimum_free
	else
		free_bytes=$percent_free
	fi
	required_bytes=$((used_bytes + free_bytes))
	if [[ -n $image_size_gib ]]; then
		image_bytes=$((image_size_gib * 1024 * 1024 * 1024))
		if (( image_bytes < required_bytes )); then
			echo "IMAGE_SIZE_GIB=$image_size_gib is too small" >&2
			echo "need at least $required_bytes bytes with the selected free-space policy" >&2
			exit 1
		fi
	else
		round_bytes=$((256 * 1024 * 1024))
		image_bytes=$(((required_bytes + round_bytes - 1) / round_bytes * round_bytes))
	fi

	raw_image="$work_dir/rootfs.raw.img"
	mkdir -p "$image_mount"
	truncate -s "$image_bytes" "$raw_image"
	if [[ $image_populator == mke2fs ]]; then
		# mke2fs copies a native rootfs tree without Android fs_config's
		# whitespace limitation, while retaining numeric ownership and modes.
		mkfs.ext4 -q -F -L linux -m 0 \
			-E lazy_itable_init=0,lazy_journal_init=0 \
			-d "$rootfs" "$raw_image"
	else
		mkfs.ext4 -q -F -L linux -m 0 \
			-E lazy_itable_init=0,lazy_journal_init=0 "$raw_image"
	fi
	if [[ $image_populator == mount ]]; then
		mount -o loop "$raw_image" "$image_mount"
		image_mounted=1
		rsync -aHAX --numeric-ids "$rootfs/" "$image_mount/"
		sync -f "$image_mount"
		unmount_image
	elif [[ $image_populator == e2fsdroid ]]; then
		fs_config="$work_dir/fs_config"
		: > "$fs_config"
		skipped_fs_config=0
		while IFS= read -r -d '' relative &&
			IFS= read -r -d '' file_uid &&
			IFS= read -r -d '' file_gid &&
			IFS= read -r -d '' file_mode; do
			if [[ $relative == *[$'\t\n ']* ]]; then
				# Android's fs_config format is whitespace-delimited. Package
				# paths containing spaces are ordinary root-owned data files;
				# e2fsdroid's defaults are correct for those entries.
				((skipped_fs_config += 1))
				continue
			fi
			if [[ -n $relative ]]; then
				config_path=$relative
			else
				config_path=/
			fi
			printf '%s %s %s 0%s\n' \
				"$config_path" "$file_uid" "$file_gid" "$file_mode" \
				>> "$fs_config"
			done < <(find "$rootfs" -printf '%P\0%U\0%G\0%m\0')
		if (( skipped_fs_config )); then
			echo "using e2fsdroid defaults for $skipped_fs_config whitespace-containing paths"
		fi
		e2fsdroid -e -C "$fs_config" -a / -f "$rootfs" "$raw_image"
	fi
	e2fsck -fn "$raw_image"
	if [[ $(blkid -s LABEL -o value "$raw_image") != linux ]]; then
		echo "generated ext4 image does not have LABEL=linux" >&2
		exit 1
	fi

	if [[ $sparse_image == 1 ]]; then
		img2simg "$raw_image" "$temporary"
	else
		mv -- "$raw_image" "$temporary"
	fi
	echo "ext4 logical size: $image_bytes bytes"
fi
mv -- "$temporary" "$output"

echo "created $output"
du -h "$output"
sha256sum "$output"
