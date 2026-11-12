#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../config/armada.env
# shellcheck disable=SC1091
source "$project_dir/config/armada.env"

output=${1:-"$project_dir/caihong-armada-rootfs.img"}
armada_image=${ARMADA_IMAGE:-ghcr.io/armada-os/armada:stable}
module_tree=${MODULE_TREE:-"$project_dir/modules-current"}
release_dir=${RELEASE_DIR:-"$project_dir/release"}
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

required_tools=(blkid bsdtar chroot depmod e2fsck find img2simg mkfs.ext4
	mount python3 rsync sha256sum skopeo systemctl umoci umount)
for tool in "${required_tools[@]}"; do
	command -v "$tool" >/dev/null 2>&1 || fail "missing host tool: $tool"
done
[[ $(uname -m) == aarch64 || $(uname -m) == arm64 ]] || \
	fail "the Armada rootfs must be assembled on an AArch64 host"
[[ -d $module_tree/lib/modules ]] || fail "missing module tree: $module_tree"
[[ -d $npu_bundle ]] || fail "missing release NPU bundle: $npu_bundle"
[[ -f $release_dir/KERNEL_RELEASE ]] || fail "missing release/KERNEL_RELEASE"
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
if [[ -z $kernel_rpm && -f $release_dir/LINUX_CAIHONG_RPM ]]; then
	kernel_rpm=$(resolve_input "$release_dir/$(<"$release_dir/LINUX_CAIHONG_RPM")" kernel RPM)
fi
[[ -n $kernel_rpm ]] || fail "a linux-caihong RPM is required to build the device rootfs"
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
SYSTEMD_OFFLINE=1 chroot "$rootfs" /usr/bin/env -i \
	HOME=/root LANG=C PATH=/usr/sbin:/usr/bin:/sbin:/bin \
	/usr/bin/dnf5 -y install --setopt=install_weak_deps=False \
	dnsmasq e2fsprogs hostapd iio-sensor-proxy openssh-server \
	android-tools python3-gobject \
	libbsd libqmi libqrtr-glib libyaml protobuf-c
rm -f -- "$rootfs/etc/resolv.conf"
if (( resolver_saved )); then
	cp -a --no-dereference "$work_dir/resolv.conf.original" "$rootfs/etc/resolv.conf"
fi

# The platform payload owns the complete device overlay, camera stack and
# board utilities.  It is installed later through the same package used for
# incremental updates; do not copy rootfs/archlinuxarm or rootfs/armada here.

rm -rf -- "$rootfs/usr/lib/modules"

echo "installing packaged Caihong update payloads"
install -d -m 0755 "$rootfs/tmp/caihong-packages"
install -m 0644 "$platform_package" \
	"$rootfs/tmp/caihong-packages/${platform_package##*/}"
if [[ -n $npu_package ]]; then
	install -m 0644 "$npu_package" \
		"$rootfs/tmp/caihong-packages/${npu_package##*/}"
fi
CAIHONG_PLATFORM_ROOT="$rootfs" CAIHONG_PLATFORM_IMAGE_BUILD=1 \
"$project_dir/packaging/caihong-platform/install-caihong-platform" \
	"$rootfs/tmp/caihong-packages/${platform_package##*/}"
if [[ -n $npu_package ]]; then
	CAIHONG_PLATFORM_ROOT="$rootfs" \
	"$project_dir/packaging/caihong-platform/install-caihong-platform" \
		"$rootfs/tmp/caihong-packages/${npu_package##*/}"
fi

install -m 0644 "$kernel_rpm" "$rootfs/tmp/linux-caihong.rpm"
chroot "$rootfs" /usr/bin/env -i \
	HOME=/root LANG=C PATH=/usr/sbin:/usr/bin:/sbin:/bin CAIHONG_SKIP_BOOT_FLASH=1 \
	/usr/bin/dnf5 -y --disablerepo='*' install /tmp/linux-caihong.rpm
chroot "$rootfs" rpm -q linux-caihong >/dev/null || \
	fail "linux-caihong RPM was not registered"
[[ $(<"$rootfs/usr/lib/linux-caihong/kernel-release") == "$kernel_release" ]] || \
	fail "installed linux-caihong RPM does not match $kernel_release"
[[ -d $rootfs/usr/lib/modules/$kernel_release ]] || \
	fail "linux-caihong RPM did not activate the matching modules"
rm -f -- "$rootfs/tmp/linux-caihong.rpm"
rm -rf -- "$rootfs/tmp/caihong-packages"

# The platform package already provided firmware, audio topology, services and
# the device overlay.  Re-copying them here would create a second producer.

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

for unit in NetworkManager.service bluetooth.service power-profiles-daemon.service \
	caihong-adbd.service \
	caihong-grow-rootfs.service caihong-fix-kwin-brightness.service \
	caihong-clean-pogo-kde.service caihong-keyboard.service caihong-bluetooth-autostart.service \
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
