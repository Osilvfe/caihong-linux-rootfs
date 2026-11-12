#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
#
# Build Caihong libcamera into an update-package stage.  The build root is
# prepared separately by caihong-build-root.sh so full images and incremental
# updates share one AArch64 environment and identical binaries.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=${1:-}
build_root=${CAIHONG_BUILD_ROOT:-}
libdir=${LIBCAMERA_LIBDIR:-lib}
build_profile=${LIBCAMERA_BUILD_PROFILE:-platform-package}
jobs=${LIBCAMERA_BUILD_JOBS:-}
source_tree="$project_dir/external/libcamera"

if [[ -z $stage || ! -d $stage ]]; then
	echo "usage: $0 STAGE_DIR" >&2
	exit 2
fi
stage=$(cd -- "$stage" && pwd)
case $stage in
	/|/boot|/home|/usr|/var)
		echo "refusing unsafe stage directory: $stage" >&2
		exit 1
		;;
esac
case $libdir in
	lib|lib64) ;;
	*) echo "LIBCAMERA_LIBDIR must be lib or lib64" >&2; exit 2 ;;
esac
if [[ -z $build_root || ! -d $build_root ]]; then
	echo "CAIHONG_BUILD_ROOT must point to a prepared AArch64 build root" >&2
	exit 1
fi
build_root=$(cd -- "$build_root" && pwd)
if [[ ! -f $source_tree/meson.build ]]; then
	echo "incomplete Caihong libcamera source tree: $source_tree" >&2
	exit 1
fi
for tool in bsdtar chroot git meson nproc rsync; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "missing host tool: $tool" >&2
		exit 1
	}
done

if [[ -d $source_tree/.git ]]; then
	if [[ -n $(git -C "$source_tree" status --porcelain --untracked-files=no) ]]; then
		echo "refusing to package uncommitted libcamera changes" >&2
		exit 1
	fi
	source_commit=$(git -C "$source_tree" rev-parse --verify HEAD)
else
	resolved="$project_dir/build/dependencies.resolved.env"
	source_commit=$(sed -n 's/^LIBCAMERA_COMMIT=//p' "$resolved" 2>/dev/null | tail -n 1)
	[[ -n $source_commit ]] || {
		echo "cannot determine the libcamera source revision" >&2
		exit 1
	}
fi

if [[ -z $jobs ]]; then
	jobs=$(nproc)
	(( jobs > 1 )) && ((jobs -= 1))
	(( jobs > 7 )) && jobs=7
fi
case $jobs in
	''|*[!0-9]*|0) echo "LIBCAMERA_BUILD_JOBS must be a positive integer" >&2; exit 1 ;;
esac

work_dir=$(mktemp -d "$project_dir/build/caihong-libcamera-stage.XXXXXX")
source_copy="$work_dir/libcamera"
install_root="$work_dir/root"
cleanup()
{
	rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$source_copy" "$install_root"
rsync -aHAX --numeric-ids --exclude=.git --exclude='build*' --exclude=.cache \
	"$source_tree/" "$source_copy/"
printf '0.7.2+caihong\n' > "$source_copy/.tarball-version"
install -d -m 0755 "$build_root/tmp" "$build_root/var/tmp"
rm -rf -- "$build_root/var/tmp/caihong-libcamera-src" \
	"$build_root/var/tmp/caihong-libcamera-build" \
	"$build_root/var/tmp/caihong-libcamera-install"
rsync -aHAX --numeric-ids "$source_copy/" "$build_root/var/tmp/caihong-libcamera-src/"

chroot_env=(/usr/bin/env -i HOME=/root LANG=C
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
echo "configuring Caihong libcamera"
chroot "$build_root" "${chroot_env[@]}" \
	meson setup /var/tmp/caihong-libcamera-build /var/tmp/caihong-libcamera-src \
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
chroot "$build_root" "${chroot_env[@]}" \
	ninja -C /var/tmp/caihong-libcamera-build -j "$jobs"
chroot "$build_root" "${chroot_env[@]}" \
	/usr/bin/env DESTDIR=/var/tmp/caihong-libcamera-install \
	ninja -C /var/tmp/caihong-libcamera-build install

required_outputs=(
	usr/bin/cam
	usr/bin/qcam
	"usr/$libdir/gstreamer-1.0/libgstlibcamera.so"
	"usr/$libdir/libcamera-base.so.0.7.2"
	"usr/$libdir/libcamera.so.0.7"
	"usr/$libdir/libcamera.so.0.7.2"
)
for path in "${required_outputs[@]}"; do
	if [[ ! -e $build_root/var/tmp/caihong-libcamera-install/$path ]]; then
		echo "Caihong libcamera install is missing /$path" >&2
		exit 1
	fi
done
rsync -aHAX --numeric-ids \
	"$build_root/var/tmp/caihong-libcamera-install/" "$install_root/"
for path in \
	usr/lib/libcamera/ipa/ipa_soft_simple.so \
	usr/lib/libcamera/ipa/ipa_soft_simple.so.sign \
	usr/lib64/libcamera/ipa/ipa_soft_simple.so \
	usr/lib64/libcamera/ipa/ipa_soft_simple.so.sign \
	usr/lib/libcamera/soft_ipa_proxy \
	usr/lib64/libcamera/soft_ipa_proxy \
	usr/libexec/libcamera/soft_ipa_proxy \
	usr/share/libcamera/ipa/simple/sc1320cs.yaml \
	usr/share/libcamera/ipa/simple/sc820cs.yaml; do
	rm -f -- "$install_root/$path"
done

install -d -m 0755 "$stage"
rsync -aHAX --numeric-ids "$install_root/" "$stage/"
# Plasma Camera and any later stage build against the same libcamera headers,
# pkg-config file and shared libraries instead of the distribution package.
if [[ -d $build_root/etc/ld.so.conf.d || -f $build_root/usr/lib/libcamera.so ]]; then
	rsync -aHAX --numeric-ids "$install_root/" "$build_root/"
	if command -v ldconfig >/dev/null 2>&1; then
		ldconfig -r "$build_root" 2>/dev/null || true
	fi
fi
install -d -m 0755 "$stage/usr/share/caihong"
build_timestamp=${SOURCE_DATE_EPOCH:+$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)}
[[ -n $build_timestamp ]] || build_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
build_id=$(printf '%s\n%s\n%s\n' "$source_commit" "$build_profile" "$build_timestamp" | sha256sum | cut -d' ' -f1)
cat > "$stage/usr/share/caihong/libcamera-build-info" <<EOF
build=caihong
version=0.7.2+caihong
source_commit=$source_commit
build_id=$build_id
build_profile=$build_profile
build_timestamp=$build_timestamp
libdir=$libdir
pipelines=simple
ipas=none
isp_backend=qcom-camera-icp-bps
isp_output=nv12m
isp_statistics=output-luma-chroma-sampling
isp_pipeline=raw10-demosaic-white-balance-ccm-gamma-nv12m
color_correction=sensor-profile-ccm
gamma=ratio-preserving-contrast
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
chmod 0644 "$stage/usr/share/caihong/libcamera-build-info"
rm -rf -- "$build_root/var/tmp/caihong-libcamera-src" \
	"$build_root/var/tmp/caihong-libcamera-build" \
	"$build_root/var/tmp/caihong-libcamera-install"
echo "Caihong libcamera staged for the platform package"
