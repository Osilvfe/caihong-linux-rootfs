#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
rootfs=${1:-}
chroot_tool=${CHROOT_TOOL:-arch-chroot}
jobs=${LIBCAMERA_BUILD_JOBS:-}
libdir=${LIBCAMERA_LIBDIR:-lib}

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
case "$libdir" in
	lib|lib64) ;;
	*)
		echo "LIBCAMERA_LIBDIR must be lib or lib64" >&2
		exit 2
		;;
esac

source_tree="$project_dir/external/libcamera"
if [[ ! -f $source_tree/meson.build ]]; then
	echo "incomplete Caihong libcamera source tree: $source_tree" >&2
	exit 1
fi

for tool in "$chroot_tool" git nproc rsync; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "missing host tool: $tool" >&2
		exit 1
	fi
done

if [[ -n $(git -C "$source_tree" status --porcelain --untracked-files=no) ]]; then
	echo "refusing to package uncommitted libcamera source changes" >&2
	exit 1
fi
source_commit=$(git -C "$source_tree" rev-parse --verify HEAD)

if [[ -z $jobs ]]; then
	jobs=$(nproc)
	if (( jobs > 1 )); then
		((jobs -= 1))
	fi
	# Native device builds use seven workers and keep one CPU free. Capping
	# rootfs builds also avoids excessive memory use under QEMU user-mode.
	if (( jobs > 7 )); then
		jobs=7
	fi
fi
case "$jobs" in
	''|*[!0-9]*|0)
		echo "LIBCAMERA_BUILD_JOBS must be a positive integer" >&2
		exit 1
		;;
esac

source_stage="$rootfs/var/tmp/libcamera-caihong-src"
build_stage="$rootfs/var/tmp/libcamera-caihong-build"
install_stage="$rootfs/var/tmp/libcamera-caihong-install"

rm -rf -- "$source_stage" "$build_stage" "$install_stage"
mkdir -p "$source_stage"
rsync -a --delete \
	--exclude='/.git/' \
	--exclude='/build*/' \
	--exclude='/.cache/' \
	--exclude='**/__pycache__/' \
	"$source_tree/" "$source_stage/"
printf '0.7.2+caihong\n' > "$source_stage/.tarball-version"

chroot_env=(/usr/bin/env -i HOME=/root LANG=C
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
source_inside=/var/tmp/libcamera-caihong-src
build_inside=/var/tmp/libcamera-caihong-build
install_inside=/var/tmp/libcamera-caihong-install

echo "configuring Caihong libcamera"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	meson setup "$build_inside" "$source_inside" \
	--buildtype=release \
	--prefix=/usr \
	--sysconfdir=/etc \
	--libdir="$libdir" \
	-Dwerror=false \
	-Dandroid=disabled \
	-Dcam=enabled \
	-Ddocumentation=disabled \
	-Dgstreamer=enabled \
	-Dipas= \
	-Dlc-compliance=disabled \
	-Dpipelines=simple \
	-Dpycamera=disabled \
	-Dqcam=enabled \
	-Dsoftisp-gpu=disabled \
	-Dtest=false \
	-Dtracing=disabled \
	-Dv4l2=disabled

echo "building Caihong libcamera with $jobs workers"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	ninja -C "$build_inside" -j "$jobs"

echo "staging Caihong libcamera"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	DESTDIR="$install_inside" ninja -C "$build_inside" install

required_outputs=(
	usr/bin/cam
	usr/bin/qcam
	"usr/$libdir/gstreamer-1.0/libgstlibcamera.so"
	"usr/$libdir/libcamera-base.so.0.7.2"
	"usr/$libdir/libcamera.so.0.7"
	"usr/$libdir/libcamera.so.0.7.2"
)
for path in "${required_outputs[@]}"; do
	if [[ ! -e $install_stage/$path ]]; then
		echo "custom libcamera install is missing /$path" >&2
		exit 1
	fi
done

echo "installing Caihong libcamera into rootfs"
rsync -aHAX --numeric-ids --chown=0:0 "$install_stage/" "$rootfs/"
obsolete_outputs=(
	usr/lib/libcamera/ipa/ipa_soft_simple.so
	usr/lib/libcamera/ipa/ipa_soft_simple.so.sign
	usr/lib64/libcamera/ipa/ipa_soft_simple.so
	usr/lib64/libcamera/ipa/ipa_soft_simple.so.sign
	usr/lib/libcamera/soft_ipa_proxy
	usr/lib64/libcamera/soft_ipa_proxy
	usr/libexec/libcamera/soft_ipa_proxy
	usr/share/libcamera/ipa/simple/sc1320cs.yaml
	usr/share/libcamera/ipa/simple/sc820cs.yaml
)
for path in "${obsolete_outputs[@]}"; do
	rm -f -- "$rootfs/$path"
done
"$chroot_tool" "$rootfs" "${chroot_env[@]}" ldconfig

install -d -m 0755 "$rootfs/usr/share/caihong"
cat > "$rootfs/usr/share/caihong/libcamera-build-info" <<EOF
build=caihong
version=0.7.2+caihong
source_commit=$source_commit
libdir=$libdir
pipelines=simple
ipas=none
isp_backend=qcom-camera-icp-bps
isp_output=nv12m
isp_statistics=output-luma-chroma-sampling
isp_pipeline=raw10-demosaic-white-balance-ccm-nv12m
color_correction=sensor-profile-ccm
gamma=deferred-until-pre-gamma-white-balance
module_abi=qcom-camera-icp-bps-matched-build
isp_validation=front-3264x2448-rear-4208x3120
validated_camera_sensors=sc820cs,sc1320cs
sensor_controls=closed-loop-exposure-gain
software_isp=disabled
software_isp_linkage=omitted
software_isp_fallback=disabled
softisp_gpu=disabled
ae_controls=unavailable
auto_exposure=output-luma-closed-loop
awb_controls=v4l2-red-blue-balance-q10
white_balance=sensor-profile-plus-adaptive
auto_white_balance=output-chroma-closed-loop
autofocus=manual-position
camera_flash=dual-v4l2
camera_flash_sync=frame-start-request-queue
camera_flash_torch_stop=led-mode
gstreamer=enabled
qcam=enabled
build_jobs=$jobs
EOF
chmod 0644 "$rootfs/usr/share/caihong/libcamera-build-info"

rm -rf -- "$source_stage" "$build_stage" "$install_stage"
echo "Caihong libcamera installed into $rootfs"
