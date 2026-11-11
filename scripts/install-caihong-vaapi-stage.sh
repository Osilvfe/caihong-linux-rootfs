#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
#
# Build the Qualcomm Iris VA-API driver directly into an update-package stage.
# The rootfs image builder can compile inside the target because it has a
# complete AArch64 userland.  The incremental platform package is assembled on
# the host, so build here with the same Meson feature set and fail closed if
# the host is not the native AArch64 release runner.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=${1:-}
source_tree="$project_dir/external/qcom-va-driver"

if [[ -z $stage || ! -d $stage ]]; then
	echo "usage: $0 STAGE_DIR" >&2
	exit 2
fi

stage=$(cd -- "$stage" && pwd)
case "$stage" in
	/|/boot|/home|/usr|/var)
		echo "refusing unsafe stage directory: $stage" >&2
		exit 1
		;;
esac

for path in meson.build meson_options.txt src/backend.cpp src/av1.cpp; do
	if [[ ! -e $source_tree/$path ]]; then
		echo "incomplete qcom-va-driver source tree: $source_tree" >&2
		exit 1
	fi
done

for tool in git meson ninja pkg-config rsync; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "missing host tool: $tool" >&2
		exit 1
	fi
done

# The driver links against the target's libva, libdrm and Mesa.  A cross build
# would need a full sysroot, so only build it where it actually runs.
if [[ $(uname -m) != aarch64 && ${CAIHONG_ALLOW_FOREIGN_VAAPI:-0} != 1 ]]; then
	echo "qcom-va-driver must be built on AArch64" >&2
	echo "set CAIHONG_ALLOW_FOREIGN_VAAPI=1 only for a deliberate cross build" >&2
	exit 1
fi

for dependency in libva libdrm egl glesv2 gbm; do
	if ! pkg-config --exists "$dependency"; then
		echo "missing build dependency: $dependency" >&2
		exit 1
	fi
done

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

# Release builds check dependencies out without using a submodule, so record
# the revision that checkout-dependencies.sh resolved even when the copied
# source tree has no .git directory.
resolved="$project_dir/build/dependencies.resolved.env"
if [[ -f $resolved ]]; then
	resolved_commit=$(sed -n 's/^QCOM_VA_COMMIT=//p' "$resolved" | tail -n 1)
	resolved_ref=$(sed -n 's/^QCOM_VA_REF=//p' "$resolved" | tail -n 1)
	if [[ -n $resolved_commit ]]; then
		source_commit=$resolved_commit
		# A pinned commit is not a readable version string; keep git's
		# describe output when the copy still has history.
		if [[ $version == unknown && -n $resolved_ref ]]; then
			version=$resolved_ref
			[[ $version =~ ^[0-9a-f]{40}$ ]] && version=${version:0:12}
		fi
	fi
fi

mkdir -p "$project_dir/build"
work_dir=$(mktemp -d "$project_dir/build/caihong-vaapi-stage.XXXXXX") || exit 1
source_copy="$work_dir/qcom-va-driver"
build_dir="$work_dir/build"
install_root="$work_dir/root"

cleanup()
{
	rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$source_copy" "$install_root"
rsync -aHAX --numeric-ids --exclude=.git "$source_tree/" "$source_copy/"

# Match scripts/install-caihong-vaapi-rootfs.sh.  CDSP and Vulkan VPP need the
# full Hexagon/Vulkan SDK and are left out of the image build, so the update
# must not silently change the feature set.  gpu_copy is explicit: "auto"
# would fall back to CPU copying when a header is missing and produce a
# package that behaves unlike the image.
meson setup "$build_dir" "$source_copy" \
	--prefix=/usr --libdir=lib --buildtype=release \
	-Dgpu_copy=enabled -Dcdsp_vpp=disabled -Dvulkan_vpp=disabled \
	-Dtests=false -Dv4l2_symlink=true
meson compile -C "$build_dir"
DESTDIR="$install_root" meson install -C "$build_dir" --no-rebuild

for path in usr/lib/dri/qcom_drv_video.so usr/lib/dri/msm_drv_video.so; do
	if [[ ! -e $install_root/$path && ! -L $install_root/$path ]]; then
		echo "Caihong VA-API install is missing /$path" >&2
		exit 1
	fi
done
if [[ ! -L $install_root/usr/lib/dri/msm_drv_video.so ]]; then
	echo "Caihong VA-API msm alias is not a symlink" >&2
	exit 1
fi

install -d -m 0755 "$stage/usr/lib/dri" "$stage/usr/share/caihong"
rsync -aHAX --numeric-ids "$install_root/usr/lib/dri/" "$stage/usr/lib/dri/"
for directory in usr/share/doc/qcom-va-driver usr/share/licenses/qcom-va-driver; do
	if [[ -d $install_root/$directory ]]; then
		install -d -m 0755 "$stage/$directory"
		rsync -aHAX --numeric-ids "$install_root/$directory/" "$stage/$directory/"
	fi
done
cat > "$stage/usr/share/caihong/vaapi-build-info" <<INFO
source_commit=$source_commit
version=$version
INFO
chmod 0644 "$stage/usr/share/caihong/vaapi-build-info"

echo "Qualcomm Iris VA-API staged for the Caihong platform package"
