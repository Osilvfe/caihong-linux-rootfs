#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
#
# Build Caihong Plasma Camera into an update-package stage from the prepared
# AArch64 build root.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=${1:-}
build_root=${CAIHONG_BUILD_ROOT:-}
jobs=${PLASMA_CAMERA_BUILD_JOBS:-}
source_tree="$project_dir/external/plasma-camera"

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
if [[ -z $build_root || ! -d $build_root ]]; then
	echo "CAIHONG_BUILD_ROOT must point to a prepared AArch64 build root" >&2
	exit 1
fi
build_root=$(cd -- "$build_root" && pwd)
for path in CMakeLists.txt src/plasmacamera.cpp src/contents/ui/camera/CameraPage.qml; do
	if [[ ! -e $source_tree/$path ]]; then
		echo "incomplete Caihong Plasma Camera source tree: $source_tree" >&2
		exit 1
	fi
done
for tool in chroot cmake git nproc rsync; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "missing host tool: $tool" >&2
		exit 1
	}
done

if [[ -d $source_tree/.git ]]; then
	if [[ -n $(git -C "$source_tree" status --porcelain --untracked-files=no) ]]; then
		echo "refusing to package uncommitted Plasma Camera changes" >&2
		exit 1
	fi
	source_commit=$(git -C "$source_tree" rev-parse --verify HEAD)
else
	resolved="$project_dir/build/dependencies.resolved.env"
	source_commit=$(sed -n 's/^PLASMA_CAMERA_COMMIT=//p' "$resolved" 2>/dev/null | tail -n 1)
	[[ -n $source_commit ]] || {
		echo "cannot determine the Plasma Camera source revision" >&2
		exit 1
	}
fi

if [[ -z $jobs ]]; then
	jobs=$(nproc)
	(( jobs > 1 )) && ((jobs -= 1))
	(( jobs > 7 )) && jobs=7
fi
case $jobs in
	''|*[!0-9]*|0) echo "PLASMA_CAMERA_BUILD_JOBS must be a positive integer" >&2; exit 1 ;;
esac

work_dir=$(mktemp -d "$project_dir/build/caihong-plasma-camera-stage.XXXXXX")
source_copy="$work_dir/plasma-camera"
install_root="$work_dir/root"
cleanup()
{
	rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$source_copy" "$install_root"
rsync -aHAX --numeric-ids --exclude=.git --exclude='build*' --exclude=.cache \
	"$source_tree/" "$source_copy/"
install -d -m 0755 "$build_root/var/tmp"
rm -rf -- "$build_root/var/tmp/caihong-plasma-camera-src" \
	"$build_root/var/tmp/caihong-plasma-camera-build" \
	"$build_root/var/tmp/caihong-plasma-camera-install"
rsync -aHAX --numeric-ids "$source_copy/" "$build_root/var/tmp/caihong-plasma-camera-src/"

chroot_env=(/usr/bin/env -i HOME=/root LANG=C
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
echo "configuring Caihong Plasma Camera"
chroot "$build_root" "${chroot_env[@]}" \
	cmake -S /var/tmp/caihong-plasma-camera-src \
	-B /var/tmp/caihong-plasma-camera-build -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX=/usr \
	-DBUILD_TESTING=OFF
echo "building Caihong Plasma Camera with $jobs workers"
chroot "$build_root" "${chroot_env[@]}" \
	cmake --build /var/tmp/caihong-plasma-camera-build --parallel "$jobs"
chroot "$build_root" "${chroot_env[@]}" \
	/usr/bin/env DESTDIR=/var/tmp/caihong-plasma-camera-install \
	cmake --install /var/tmp/caihong-plasma-camera-build

for path in usr/bin/plasma-camera usr/share/applications/org.kde.plasma.camera.desktop; do
	if [[ ! -e $build_root/var/tmp/caihong-plasma-camera-install/$path ]]; then
		echo "Caihong Plasma Camera install is missing /$path" >&2
		exit 1
	fi
done
rsync -aHAX --numeric-ids \
	"$build_root/var/tmp/caihong-plasma-camera-install/" "$install_root/"
rsync -aHAX --numeric-ids "$install_root/" "$stage/"
install -d -m 0755 "$stage/usr/share/caihong"
cat > "$stage/usr/share/caihong/plasma-camera-build-info" <<EOF
build=caihong
version=26.08.1
source_commit=$source_commit
backend=libcamera-direct
autofocus=single-trigger
white_balance=presets
noise_reduction=selectable
sharpness=selectable
flash=off-single-torch
flash_torch_intensity=200000
flash_capture_intensity=500000
video_frame_rate=libcamera-frame-duration
photo_quality=jpeg-95
build_jobs=$jobs
EOF
chmod 0644 "$stage/usr/share/caihong/plasma-camera-build-info"
rm -rf -- "$build_root/var/tmp/caihong-plasma-camera-src" \
	"$build_root/var/tmp/caihong-plasma-camera-build" \
	"$build_root/var/tmp/caihong-plasma-camera-install"
echo "Caihong Plasma Camera staged for the platform package"
