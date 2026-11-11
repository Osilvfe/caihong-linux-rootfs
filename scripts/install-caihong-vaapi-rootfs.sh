#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
rootfs=${1:-}
source_tree="$project_dir/external/qcom-va-driver"
chroot_tool=${CHROOT_TOOL:-arch-chroot}

if [[ -z $rootfs || ! -d $rootfs ]]; then
	echo "usage: $0 ROOTFS_DIR" >&2
	exit 2
fi

rootfs=$(cd -- "$rootfs" && pwd)
case "$rootfs" in
	/|/boot|/home|/usr|/var)
		echo "refusing unsafe rootfs directory: $rootfs" >&2
		exit 1
		;;
esac

for path in meson.build meson_options.txt src/backend.cpp src/av1.cpp; do
	if [[ ! -e $source_tree/$path ]]; then
		echo "incomplete qcom-va-driver source tree: $source_tree" >&2
		exit 1
	fi
done

for tool in git rsync; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "missing host tool: $tool" >&2
		exit 1
	fi
done
if ! command -v "$chroot_tool" >/dev/null 2>&1; then
	echo "missing chroot tool: $chroot_tool" >&2
	exit 1
fi

if [[ -d $source_tree/.git ]]; then
	if [[ -n $(git -C "$source_tree" status --porcelain --untracked-files=no) ]]; then
		echo "refusing to package uncommitted qcom-va-driver changes" >&2
		exit 1
	fi
	source_commit=$(git -C "$source_tree" rev-parse --verify HEAD)
	version=$(git -C "$source_tree" describe --tags --always --dirty 2>/dev/null || printf 'unknown')
else
	source_commit=unknown
	version=unknown
fi

stage_parent="$rootfs/tmp"
work_dir=$(mktemp -d "$stage_parent/qcom-va-driver.XXXXXX") || exit 1
source_copy="$work_dir/qcom-va-driver"
build_dir="$work_dir/build"

cleanup()
{
	rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$source_copy"
rsync -aHAX --numeric-ids --exclude=.git "$source_tree/" "$source_copy/"

chroot_env=(/usr/bin/env -i HOME=/root LANG=C PATH=/usr/local/sbin:/usr/local/bin:/usr/bin)
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	meson setup "$build_dir" "$source_copy" \
	--prefix=/usr --libdir=lib --buildtype=release \
	-Dgpu_copy=enabled -Dcdsp_vpp=disabled -Dvulkan_vpp=disabled \
	-Dtests=false
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	meson compile -C "$build_dir"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	meson install -C "$build_dir" --no-rebuild

for path in usr/lib/dri/qcom_drv_video.so usr/lib/dri/msm_drv_video.so; do
	if [[ ! -e $rootfs/$path && ! -L $rootfs/$path ]]; then
		echo "Caihong VA-API install is missing /$path" >&2
		exit 1
	fi
done
if [[ ! -L $rootfs/usr/lib/dri/msm_drv_video.so ]]; then
	echo "Caihong VA-API msm alias is not a symlink" >&2
	exit 1
fi

install -d -m 0755 "$rootfs/usr/share/caihong"
cat > "$rootfs/usr/share/caihong/vaapi-build-info" <<INFO
source_commit=$source_commit
version=$version
INFO
chmod 0644 "$rootfs/usr/share/caihong/vaapi-build-info"

echo "Qualcomm Iris VA-API installed into $rootfs"
