#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
release_dir=${1:-"$project_dir/release"}
version=${CAIHONG_PLATFORM_VERSION:-0.$(git -C "$project_dir" log -1 --format=%ct).g$(git -C "$project_dir" rev-parse --short HEAD)}
kernel_release=${KERNEL_RELEASE:-}
distribution=${DISTRIBUTION:-archlinuxarm}
case $distribution in
	archlinuxarm) libdir=${LIBDIR:-lib} ;;
	armada) libdir=${LIBDIR:-lib64} ;;
	*) echo "DISTRIBUTION must be archlinuxarm or armada" >&2; exit 2 ;;
esac
build_root=${CAIHONG_BUILD_ROOT:-"$project_dir/build/platform-build-root-$distribution"}

for tool in bsdtar file git install python3 sha256sum zstd; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "missing build tool: $tool" >&2
		exit 1
	fi
done
case $libdir in
	lib|lib64) ;;
	*) echo "LIBDIR must be lib or lib64" >&2; exit 2 ;;
esac
if { [ "$distribution" = archlinuxarm ] && [ "$libdir" != lib ]; } ||
	{ [ "$distribution" = armada ] && [ "$libdir" != lib64 ]; }; then
	echo "incorrect library layout for $distribution: $libdir" >&2
	exit 2
fi
if [ -n "$kernel_release" ] && [ ! -d "$project_dir/modules-current/lib/modules/$kernel_release" ]; then
	echo "KERNEL_RELEASE does not exist in modules-current: $kernel_release" >&2
	exit 1
fi
if [ -z "$kernel_release" ]; then
	kernel_release=$(cat "$project_dir/release/KERNEL_RELEASE" 2>/dev/null || true)
fi
if [ -z "$kernel_release" ]; then
	for candidate in "$project_dir"/modules-current/lib/modules/*; do
		[ -d "$candidate" ] || continue
		[ -z "${found_release:-}" ] || {
			echo "module tree contains multiple kernel releases; set KERNEL_RELEASE" >&2
			exit 1
		}
		found_release=${candidate##*/}
	done
	kernel_release=${found_release:-}
fi
[ -n "$kernel_release" ] || echo "warning: kernel release is unknown; installer will not enforce it" >&2

mkdir -p "$project_dir/build"
work_dir=$(mktemp -d "$project_dir/build/caihong-platform-package.XXXXXX") || exit 1
stage="$work_dir/stage"
mkdir -p "$release_dir" "$stage/usr" "$stage/etc"
find "$stage" -xdev -type d -exec chmod 0755 {} +
find "$stage" -xdev -type f -exec chmod go-w {} +

cleanup()
{
	"$project_dir/scripts/caihong-build-root.sh" cleanup "$build_root" \
		>/dev/null 2>&1 || true
	rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

cp -a "$project_dir/rootfs/archlinuxarm/." "$stage/"
if [ "$distribution" = armada ]; then
	cp -a "$project_dir/rootfs/armada/." "$stage/"
	for path in \
		etc/systemd/system/caihong-clean-pogo-kde.service \
		usr/local/sbin/caihong-clean-pogo-kde \
		usr/local/sbin/caihong-fix-kwin-brightness; do
		sed -i \
			-e 's#/home/alarm#/var/home/armada#g' \
			-e 's#machine=alarm@#machine=armada@#g' \
			-e 's#-o alarm -g alarm#-o armada -g armada#g' \
			-e 's#chown alarm:alarm#chown armada:armada#g' \
			"$stage/$path"
		if grep -Eq '/home/alarm|machine=alarm@' "$stage/$path"; then
			echo "unadapted Armada account reference: $path" >&2
			exit 1
		fi
	done
	sed -i 's#/usr/bin/resize2fs#/usr/sbin/resize2fs#g' \
		"$stage/etc/systemd/system/caihong-grow-rootfs.service"
	# Armada has its own account layout and does not use the Arch alarm user.
	rm -f -- "$stage/etc/sudoers.d/10-alarm"
fi

if [ "$distribution" = archlinuxarm ] || [ "$distribution" = armada ]; then
	"$project_dir/scripts/caihong-build-root.sh" prepare \
		"$build_root" "$distribution"
	CAIHONG_BUILD_ROOT="$build_root" \
	"$project_dir/scripts/install-caihong-toolbox-rootfs.sh" "$stage"
	CAIHONG_BUILD_ROOT="$build_root" LIBDIR="$libdir" \
	"$project_dir/scripts/install-caihong-vaapi-stage.sh" "$stage"
	CAIHONG_BUILD_ROOT="$build_root" LIBCAMERA_LIBDIR="$libdir" \
	"$project_dir/scripts/install-caihong-libcamera-stage.sh" "$stage"
	CAIHONG_BUILD_ROOT="$build_root" \
	"$project_dir/scripts/install-caihong-plasma-camera-stage.sh" "$stage"
	CAIHONG_BUILD_ROOT="$build_root" \
	"$project_dir/scripts/install-caihong-qbootctl-stage.sh" "$stage"
	CAIHONG_BUILD_ROOT="$build_root" \
	"$project_dir/scripts/install-caihong-utilities-stage.sh" "$stage"
	CAIHONG_BUILD_ROOT="$build_root" \
	"$project_dir/scripts/install-caihong-ppd-stage.sh" "$stage"
fi

(
	cd "$project_dir/firmware" && sha256sum -c SHA256SUMS >/dev/null
)
install -d -m 0755 "$stage/usr/lib/firmware"
cp -a "$project_dir/firmware/." "$stage/usr/lib/firmware/"
rm -f "$stage/usr/lib/firmware/SOURCE.md" "$stage/usr/lib/firmware/SHA256SUMS"

mkdir -p "$stage/usr/lib/firmware/qcom/sm8650"
if command -v alsatplg >/dev/null 2>&1; then
	"$project_dir/scripts/build-caihong-audioreach-topology.sh" \
		"$stage/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin" >/dev/null
else
	install -m 0644 "$project_dir/firmware/qcom/sm8650/SM8650-MTP-tplg.bin" \
		"$stage/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin"
fi

CAIHONG_ADBD_CACHE="$project_dir/downloads/caihong-adbd" \
	"$project_dir/scripts/install-caihong-adbd.sh" "$stage" >/dev/null
FORCE=1 "$project_dir/scripts/ssc/install-rootfs.sh" \
	"$project_dir/firmware-assets/caihong-ssc" "$stage" >/dev/null
install -d -m 0755 "$stage/usr/share/caihong-ssc"
mv -- "$stage/var/lib/caihong-ssc/root" "$stage/usr/share/caihong-ssc/root"
CAIHONG_BUILD_ROOT="$build_root" \
	"$project_dir/scripts/install-caihong-ssc-stage.sh" "$stage"

"$project_dir/scripts/install-caihong-npu.sh" \
	"$project_dir/firmware-assets/caihong-npu" "$stage" "$libdir"
printf '%s\n' "$libdir" > "$stage/usr/share/caihong-npu/libdir"
install -d -m 0755 "$stage/usr/share/caihong-platform"
"$project_dir/scripts/caihong-build-root.sh" cleanup "$build_root"
printf '%s\n' "$distribution" > "$stage/usr/share/caihong-platform/distribution"
[ -z "$kernel_release" ] || printf '%s\n' "$kernel_release" \
	> "$stage/usr/share/caihong-platform/kernel-release"
printf '%s\n' "libdir=$libdir" \
	> "$stage/usr/share/caihong-platform/layout"

python3 "$project_dir/scripts/package-caihong-platform.py" "$stage" "$release_dir" \
	--distribution "$distribution" --version "$version"

rm -rf "$work_dir"
trap - EXIT HUP INT TERM
