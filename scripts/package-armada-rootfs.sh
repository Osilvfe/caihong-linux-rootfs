#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../armada.env
# shellcheck disable=SC1091
source "$project_dir/armada.env"

output=${1:-"$project_dir/caihong-armada-rootfs.img"}
armada_image=${ARMADA_IMAGE:-ghcr.io/armada-os/armada:stable}
module_tree=${MODULE_TREE:-"$project_dir/modules-current"}
release_dir=${RELEASE_DIR:-"$project_dir/release"}
ssc_bundle=${SSC_BUNDLE:-"$project_dir/firmware-assets/caihong-ssc"}
npu_bundle=${NPU_BUNDLE:-"$project_dir/firmware-assets/caihong-npu"}
platform_package=${CAIHONG_PLATFORM_PACKAGE:-}
npu_package=${CAIHONG_NPU_PACKAGE:-}
kernel_rpm=${KERNEL_RPM:-}
image_min_free_mib=${IMAGE_MIN_FREE_MIB:-2048}
image_slack_percent=${IMAGE_SLACK_PERCENT:-25}
sparse_image=${SPARSE_IMAGE:-1}

fail()
{
	echo "package-armada-rootfs: $*" >&2
	exit 1
}

if (( EUID != 0 )); then
	fail "run this script as root"
fi
case "$image_min_free_mib:$image_slack_percent:$sparse_image" in
	*[!0-9:]*|:*|*:) fail "invalid image sizing option" ;;
esac
(( image_min_free_mib >= 512 )) || fail "IMAGE_MIN_FREE_MIB must be at least 512"
(( image_slack_percent >= 5 )) || fail "IMAGE_SLACK_PERCENT must be at least 5"
[[ $sparse_image == 0 || $sparse_image == 1 ]] || fail "SPARSE_IMAGE must be 0 or 1"

required_tools=(blkid bsdtar cc chroot depmod e2fsck file find img2simg meson
	mkfs.ext4 mount ninja python3 rsync sha256sum skopeo systemctl umoci umount)
for tool in "${required_tools[@]}"; do
	command -v "$tool" >/dev/null 2>&1 || fail "missing host tool: $tool"
done
[[ $(uname -m) == aarch64 || $(uname -m) == arm64 ]] || \
	fail "the Armada rootfs must be assembled on an AArch64 host"
[[ -d $module_tree/lib/modules ]] || fail "missing module tree: $module_tree"
[[ -d $npu_bundle ]] || fail "missing release NPU bundle: $npu_bundle"
[[ -f $release_dir/KERNEL_RELEASE ]] || fail "missing release/KERNEL_RELEASE"
[[ -f $project_dir/external/qbootctl/meson.build ]] || \
	fail "missing qbootctl source; run scripts/checkout-dependencies.sh"
platform_pointer=$release_dir/CAIHONG_PLATFORM_PACKAGE_ARMADA
[[ -f $platform_pointer ]] || platform_pointer=$release_dir/CAIHONG_PLATFORM_PACKAGE
npu_pointer=$release_dir/CAIHONG_NPU_PACKAGE_LIB64
[[ -f $npu_pointer ]] || npu_pointer=$release_dir/CAIHONG_NPU_PACKAGE

resolve_input()
{
	local input=$1 label=$2
	if [[ -n $input ]]; then
		input=$(cd -- "$(dirname -- "$input")" && pwd)/${input##*/}
		[[ -f $input ]] || fail "$label not found: $input"
	fi
	printf '%s\n' "$input"
}

platform_package=$(resolve_input "$platform_package" platform package)
npu_package=$(resolve_input "$npu_package" NPU package)
kernel_rpm=$(resolve_input "$kernel_rpm" kernel RPM)
[[ -n $platform_package ]] || \
	[[ -f $platform_pointer ]] || fail "missing Armada platform package pointer"
[[ -n $platform_package ]] || platform_package=$release_dir/$(<"$platform_pointer")
[[ -n $npu_package ]] || \
	[[ -f $npu_pointer ]] || fail "missing lib64 NPU package pointer"
[[ -n $npu_package ]] || npu_package=$release_dir/$(<"$npu_pointer")
platform_package=$(resolve_input "$platform_package" platform package)
npu_package=$(resolve_input "$npu_package" NPU package)

platform_distribution=$(bsdtar -xOf "$platform_package" \
	usr/share/caihong-platform/distribution)
[[ $platform_distribution == armada ]] || \
	fail "platform package targets $platform_distribution, expected armada"
npu_libdir=$(bsdtar -xOf "$npu_package" usr/share/caihong-npu/libdir)
[[ $npu_libdir == lib64 ]] || \
	fail "NPU package uses $npu_libdir, expected lib64"

kernel_release=$(<"$release_dir/KERNEL_RELEASE")
[[ -d $module_tree/lib/modules/$kernel_release ]] || \
	fail "module tree does not contain $kernel_release"
image_file="$release_dir/Image-$kernel_release"
dtb_file="$release_dir/sm8650-oneplus-caihong-$kernel_release.dtb"
boot_linux="$release_dir/caihong-boot-linux-$kernel_release.img"
boot_userdata="$release_dir/caihong-boot-userdata-$kernel_release.img"
for input in "$image_file" "$dtb_file" "$boot_linux" "$boot_userdata"; do
	[[ -f $input ]] || fail "missing kernel release input: $input"
done

mkdir -p "$project_dir/build" "$(dirname -- "$output")"
work_dir=$(mktemp -d "$project_dir/build/armada-rootfs.XXXXXX")
oci_dir="$work_dir/oci"
bundle="$work_dir/bundle"
rootfs="$bundle/rootfs"
image_mount="$work_dir/image-mount"
raw_image="$work_dir/rootfs.raw.img"
temporary="$output.new"
image_mounted=0

cleanup()
{
	if (( image_mounted )); then
		umount "$image_mount" 2>/dev/null || true
	fi
	rm -rf -- "$work_dir"
	rm -f -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

echo "resolving Armada image: $armada_image"
armada_arch=$(skopeo inspect --override-arch arm64 \
	--format '{{.Architecture}}' "docker://$armada_image")
[[ $armada_arch == arm64 ]] || fail "Armada image architecture is $armada_arch, expected arm64"
armada_digest=$(skopeo inspect --override-arch arm64 \
	--format '{{.Digest}}' "docker://$armada_image")
[[ $armada_digest == sha256:* ]] || fail "unable to resolve Armada image digest"

echo "copying Armada $armada_digest"
skopeo copy --override-arch arm64 --retry-times 3 \
	"docker://$armada_image" "oci:$oci_dir:armada"
umoci unpack --image "$oci_dir:armada" "$bundle"

[[ -f $rootfs/usr/lib/os-release ]] || fail "Armada image has no os-release"
grep -qx 'ID=armada' "$rootfs/usr/lib/os-release" || \
	fail "OCI image is not Armada"
[[ -x $rootfs/sbin/init || -x $rootfs/usr/lib/systemd/systemd ]] || \
	fail "Armada image has no systemd init"
[[ -x $rootfs/var/home/armada/.local/share/Steam/steamrtarm64/steam ]] || \
	fail "Armada Steam Client bootstrap is missing"

# Armada targets btrfs bootc installations and intentionally keeps its base
# small. The Android direct-root image needs ext4 growth, SSH, the Caihong
# hotspot dependencies, sensors and the camera build/runtime dependencies.
# Install them from the same Fedora release used by the resolved Armada image.
echo "installing direct-root runtime packages into Armada"
resolver_saved=0
if [[ -e $rootfs/etc/resolv.conf || -L $rootfs/etc/resolv.conf ]]; then
	cp -a --no-dereference "$rootfs/etc/resolv.conf" "$work_dir/resolv.conf.original"
	resolver_saved=1
fi
rm -f -- "$rootfs/etc/resolv.conf"
cp -L /etc/resolv.conf "$rootfs/etc/resolv.conf"
camera_build_packages=(
	gcc gcc-c++ cmake extra-cmake-modules gettext meson ninja-build pkgconf-pkg-config
	python3-jinja2 python3-ply python3-pyyaml
	gnutls-devel libyaml-devel libevent-devel libunwind-devel openssl-devel
	elfutils-libelf-devel libdrm-devel libjpeg-turbo-devel systemd-devel wayland-devel
	mesa-libEGL-devel mesa-libGLES-devel
	gstreamer1-devel gstreamer1-plugins-base-devel
	qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtmultimedia-devel
	qt6-qtsensors-devel qt6-qtsvg-devel
	kf6-kconfig-devel kf6-kcoreaddons-devel kf6-ki18n-devel
	kf6-kirigami-devel kf6-kirigami-addons-devel exiv2-devel
)
camera_build_remove=()
for package in "${camera_build_packages[@]}"; do
	if ! chroot "$rootfs" rpm -q "$package" >/dev/null 2>&1; then
		camera_build_remove+=("$package")
	fi
done
SYSTEMD_OFFLINE=1 chroot "$rootfs" /usr/bin/env -i \
	HOME=/root LANG=C PATH=/usr/sbin:/usr/bin:/sbin:/bin \
	/usr/bin/dnf5 -y install --setopt=install_weak_deps=False \
	dnsmasq e2fsprogs hostapd iio-sensor-proxy openssh-server \
	android-tools \
	libbsd libqmi libqrtr-glib libyaml protobuf-c \
	libcamera libcamera-ipa libcamera-tools libcamera-qcam \
	libcamera-gstreamer plasma-camera \
	"${camera_build_packages[@]}"
rm -f -- "$rootfs/etc/resolv.conf"
if (( resolver_saved )); then
	cp -a --no-dereference "$work_dir/resolv.conf.original" "$rootfs/etc/resolv.conf"
fi

echo "overlaying Caihong board integration"
rsync -aHAX --numeric-ids --chown=0:0 \
	"$project_dir/rootfs/archlinuxarm/" "$rootfs/"
rsync -aHAX --numeric-ids --chown=0:0 \
	"$project_dir/rootfs/armada/" "$rootfs/"
rm -f -- "$rootfs/etc/sudoers.d/10-alarm"
rm -f -- "$rootfs/etc/alsa/state-daemon.conf"

echo "building and installing the Caihong libcamera stack"
CHROOT_TOOL=chroot LIBCAMERA_LIBDIR=lib64 \
	"$project_dir/scripts/install-caihong-libcamera-rootfs.sh" "$rootfs"

echo "building and installing Caihong Plasma Camera"
CHROOT_TOOL=chroot \
	"$project_dir/scripts/install-caihong-plasma-camera-rootfs.sh" "$rootfs"

if (( ${#camera_build_remove[@]} )); then
	echo "removing temporary camera build packages"
	SYSTEMD_OFFLINE=1 chroot "$rootfs" /usr/bin/env -i \
		HOME=/root LANG=C PATH=/usr/sbin:/usr/bin:/sbin:/bin \
		/usr/bin/dnf5 -y remove "${camera_build_remove[@]}"
fi
SYSTEMD_OFFLINE=1 chroot "$rootfs" /usr/bin/env -i \
	HOME=/root LANG=C PATH=/usr/sbin:/usr/bin:/sbin:/bin \
	/usr/bin/dnf5 clean all

# The regular image uses the Arch Linux ARM account. Armada owns its account
# and home layout, so adjust only the three Caihong KDE integration files.
python3 - "$rootfs" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
files = (
    root / "etc/systemd/system/caihong-clean-pogo-kde.service",
    root / "usr/local/sbin/caihong-clean-pogo-kde",
    root / "usr/local/sbin/caihong-fix-kwin-brightness",
)
replacements = (
    ("/home/alarm", "/var/home/armada"),
    ("machine=alarm@", "machine=armada@"),
    ("-o alarm -g alarm", "-o armada -g armada"),
    ("chown alarm:alarm", "chown armada:armada"),
)
for path in files:
    text = path.read_text()
    for old, new in replacements:
        text = text.replace(old, new)
    if "/home/alarm" in text or "machine=alarm@" in text:
        raise SystemExit(f"unadapted Arch Linux ARM account reference: {path}")
    path.write_text(text)
PY

# Fedora installs resize2fs in sbin while Arch installs it in bin.
grow_unit="$rootfs/etc/systemd/system/caihong-grow-rootfs.service"
if [[ -x $rootfs/usr/sbin/resize2fs ]]; then
	sed -i 's#/usr/bin/resize2fs#/usr/sbin/resize2fs#' "$grow_unit"
elif [[ ! -x $rootfs/usr/bin/resize2fs ]]; then
	fail "Armada image does not contain resize2fs"
fi

echo "building Caihong hardware-address reader"
install -d -m 0755 "$rootfs/usr/local/libexec"
cc -O2 -Wall -Wextra -Werror \
	-o "$rootfs/usr/local/libexec/caihong-nvram-mac" \
	"$project_dir/tools/caihong-nvram-mac.c" -lcrypto
file "$rootfs/usr/local/libexec/caihong-nvram-mac" | grep -q 'ARM aarch64' || \
	fail "Caihong hardware-address reader is not AArch64"

echo "building Caihong NPU capability probe"
cc -O2 -Wall -Wextra -Werror \
	-o "$rootfs/usr/local/sbin/caihong-npu-info" \
	"$project_dir/tools/caihong-npu-info.c" -ldl
file "$rootfs/usr/local/sbin/caihong-npu-info" | grep -q 'ARM aarch64' || \
	fail "Caihong NPU capability probe is not AArch64"

echo "installing Caihong firmware and AudioReach topology"
(cd "$project_dir/firmware" && sha256sum -c SHA256SUMS)
install -d -m 0755 "$rootfs/usr/lib/firmware"
rsync -aHAX --numeric-ids --chown=0:0 \
	--exclude=SOURCE.md --exclude=SHA256SUMS \
	"$project_dir/firmware/" "$rootfs/usr/lib/firmware/"
"$project_dir/scripts/build-caihong-audioreach-topology.sh" \
	"$rootfs/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin"

echo "installing Caihong sensor service"
FORCE=1 "$project_dir/scripts/ssc/install-rootfs.sh" "$ssc_bundle" "$rootfs"

echo "installing matching Caihong kernel modules"
rm -rf -- "$rootfs/usr/lib/modules"
CAIHONG_EXPECTED_RELEASE="$kernel_release" \
	"$project_dir/scripts/install-caihong-modules.sh" "$module_tree" "$rootfs"
rm -f -- "$rootfs/usr/local/lib/caihong/caihong_pen_power.ko"
"$project_dir/scripts/install-caihong-adbd.sh" "$rootfs"

echo "installing packaged Caihong update payloads"
install -d -m 0755 "$rootfs/tmp/caihong-packages"
if [[ -n $platform_package ]]; then
	install -m 0644 "$platform_package" \
		"$rootfs/tmp/caihong-packages/${platform_package##*/}"
fi
if [[ -n $npu_package ]]; then
	install -m 0644 "$npu_package" \
		"$rootfs/tmp/caihong-packages/${npu_package##*/}"
fi
if [[ -n $platform_package ]]; then
	CAIHONG_PLATFORM_ROOT="$rootfs" \
	"$project_dir/packaging/caihong-platform/install-caihong-platform" \
		"$rootfs/tmp/caihong-packages/${platform_package##*/}"
fi
if [[ -n $npu_package ]]; then
	CAIHONG_PLATFORM_ROOT="$rootfs" \
	"$project_dir/packaging/caihong-platform/install-caihong-platform" \
		"$rootfs/tmp/caihong-packages/${npu_package##*/}"
fi

if [[ -n $kernel_rpm ]]; then
	install -m 0644 "$kernel_rpm" "$rootfs/tmp/linux-caihong.rpm"
	chroot "$rootfs" /usr/bin/env -i \
		HOME=/root LANG=C PATH=/usr/sbin:/usr/bin:/sbin:/bin \
		/usr/bin/dnf5 -y --disablerepo='*' install /tmp/linux-caihong.rpm
	chroot "$rootfs" rpm -q linux-caihong >/dev/null || \
		fail "linux-caihong RPM was not registered"
	rm -f -- "$rootfs/tmp/linux-caihong.rpm"
fi
rm -rf -- "$rootfs/tmp/caihong-packages"

echo "restoring Caihong firmware and AudioReach topology"
install -d -m 0755 "$rootfs/usr/lib/firmware"
rsync -aHAX --numeric-ids --chown=0:0 \
	--exclude=SOURCE.md --exclude=SHA256SUMS \
	"$project_dir/firmware/" "$rootfs/usr/lib/firmware/"
"$project_dir/scripts/build-caihong-audioreach-topology.sh" \
	"$rootfs/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin"

echo "installing Caihong boot payload metadata"
install -d -m 0755 "$rootfs/usr/lib/linux-caihong"
install -m 0644 "$image_file" "$rootfs/usr/lib/linux-caihong/Image"
install -m 0644 "$dtb_file" "$rootfs/usr/lib/linux-caihong/caihong.dtb"
install -m 0644 "$boot_linux" "$rootfs/usr/lib/linux-caihong/boot-linux.img"
install -m 0644 "$boot_userdata" "$rootfs/usr/lib/linux-caihong/boot-userdata.img"
install -m 0755 "$project_dir/packaging/linux-caihong/install-current-slot" \
	"$rootfs/usr/lib/linux-caihong/install-current-slot"
printf '%s\n' "$kernel_release" > "$rootfs/usr/lib/linux-caihong/kernel-release"

echo "building qbootctl"
qbootctl_build="$work_dir/qbootctl-build"
meson setup "$qbootctl_build" "$project_dir/external/qbootctl" \
	--buildtype=release --prefix=/usr/local --bindir=sbin
meson compile -C "$qbootctl_build"
DESTDIR="$rootfs" meson install -C "$qbootctl_build" --no-rebuild
[[ -x $rootfs/usr/local/sbin/qbootctl ]] || fail "qbootctl install failed"
file "$rootfs/usr/local/sbin/qbootctl" | grep -q 'ARM aarch64' || \
	fail "qbootctl is not AArch64"

printf 'caihong\n' > "$rootfs/etc/hostname"
printf 'LANG=en_US.UTF-8\n' > "$rootfs/etc/locale.conf"
cat > "$rootfs/etc/fstab" <<'EOF'
LABEL=linux / ext4 rw,noatime 0 1
EOF
rm -f -- "$rootfs/etc/machine-id"
: > "$rootfs/etc/machine-id"
# New Caihong overlay files receive their Fedora policy labels on first boot.
: > "$rootfs/.autorelabel"

enable_unit()
{
	local unit=$1
	if ! systemctl --root="$rootfs" enable "$unit" >/dev/null; then
		fail "failed to enable $unit in Armada rootfs"
	fi
}

for unit in NetworkManager.service bluetooth.service \
	caihong-adbd.service \
	caihong-grow-rootfs.service caihong-fix-kwin-brightness.service \
	caihong-clean-pogo-kde.service caihong-bluetooth-autostart.service \
	caihong-bluetooth-late-autostart.timer \
	caihong-hardware-mac.service caihong-mark-boot-successful.service \
	caihong-ssc.service caihong-pen-autoconnect.timer \
	caihong-pen-charge.timer caihong-pen-pair.timer; do
	enable_unit "$unit"
done
if systemctl --root="$rootfs" list-unit-files sshd.service --no-legend 2>/dev/null |
	grep -q '^sshd.service'; then
	enable_unit sshd.service
fi
systemctl --root="$rootfs" set-default graphical.target >/dev/null

install -d -m 0755 "$rootfs/usr/share/caihong"
cat > "$rootfs/etc/caihong-rootfs-build-info" <<EOF
device=caihong
architecture=aarch64
distribution=armada
armada_image=$armada_image
armada_digest=$armada_digest
kernel_release=$kernel_release
boot_roots=PARTLABEL=linux,PARTLABEL=userdata
boot_kernel=android-boot-v2-direct-root
steam_client=included-by-upstream-armada
rootfs_update_mode=rebuilt-image
EOF
chmod 0644 "$rootfs/etc/caihong-rootfs-build-info"

"$project_dir/scripts/verify-armada-rootfs.sh" "$rootfs"

echo "creating $output"
used_bytes=$(du -sx --block-size=1 "$rootfs" | awk 'NR == 1 { print $1 }')
percent_free=$((used_bytes * image_slack_percent / 100))
minimum_free=$((image_min_free_mib * 1024 * 1024))
if (( percent_free < minimum_free )); then
	free_bytes=$minimum_free
else
	free_bytes=$percent_free
fi
required_bytes=$((used_bytes + free_bytes))
round_bytes=$((256 * 1024 * 1024))
image_bytes=$(((required_bytes + round_bytes - 1) / round_bytes * round_bytes))

mkdir -p "$image_mount"
truncate -s "$image_bytes" "$raw_image"
mkfs.ext4 -q -F -L linux -m 0 \
	-E lazy_itable_init=0,lazy_journal_init=0 "$raw_image"
mount -o loop "$raw_image" "$image_mount"
image_mounted=1
rsync -aHAX --numeric-ids "$rootfs/" "$image_mount/"
sync -f "$image_mount"
umount "$image_mount"
image_mounted=0
e2fsck -fy "$raw_image" >/dev/null
[[ $(blkid -s LABEL -o value "$raw_image") == linux ]] || \
	fail "generated ext4 image does not have LABEL=linux"

rm -f -- "$temporary"
if [[ $sparse_image == 1 ]]; then
	img2simg "$raw_image" "$temporary"
else
	mv -- "$raw_image" "$temporary"
fi
mv -- "$temporary" "$output"
trap - EXIT HUP INT TERM
rm -rf -- "$work_dir"

echo "created $output"
echo "Armada source: $armada_image ($armada_digest)"
echo "ext4 logical size: $image_bytes bytes"
du -h "$output"
sha256sum "$output"
