#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -Eeuo pipefail
CDPATH=

release_dir=${1:-}
platform_only=0
if [[ ${2:-} == --platform-only ]]; then
	platform_only=1
elif [[ -n ${2:-} ]]; then
	echo "usage: $0 RELEASE_DIR [--platform-only]" >&2
	exit 2
fi
if [[ -z $release_dir || ! -d $release_dir ]]; then
	echo "usage: $0 RELEASE_DIR [--platform-only]" >&2
	exit 2
fi
release_dir=$(cd -- "$release_dir" && pwd)

fail()
{
	echo "verify-caihong-update-packages: $*" >&2
	exit 1
}

for tool in bsdtar grep; do
	command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done

resolve_pointer()
{
	local pointer=$1 prefix=$2 suffix=$3 name archive
	[[ -f $release_dir/$pointer ]] || fail "missing pointer: $pointer"
	name=$(<"$release_dir/$pointer")
	case $name in
		''|*/*) fail "invalid package name in $pointer: ${name:-empty}" ;;
		"$prefix"*"$suffix") ;;
		*) fail "$pointer references unexpected package: $name" ;;
	esac
	archive=$release_dir/$name
	[[ -f $archive ]] || fail "$pointer references a missing package: $name"
	printf '%s\n' "$archive"
}

verify_platform()
{
	local pointer=$1 prefix=$2 distribution=$3 archive listing removals path
	archive=$(resolve_pointer "$pointer" "$prefix" .tar.zst)
	[[ $(bsdtar -xOf "$archive" usr/share/caihong-platform/distribution) == "$distribution" ]] || \
		fail "$archive has incorrect distribution metadata"
	listing=$(bsdtar -tf "$archive")
	grep -Fqx remove <<<"$listing" || fail "$archive has no removal manifest"
	removals=$(bsdtar -xOf "$archive" remove)
	for path in \
		usr/share/caihong-package/architecture \
		usr/share/caihong-package/package \
		usr/share/caihong-package/version \
		usr/share/libcamera/ipa/simple/sc1320cs.yaml \
		usr/share/libcamera/ipa/simple/sc820cs.yaml; do
		grep -Fqx "$path" <<<"$removals" || \
			fail "$archive does not remove superseded path: $path"
	done
	for path in \
		usr/share/libcamera/ipa/simple/sc1320cs.yaml \
		usr/share/libcamera/ipa/simple/sc820cs.yaml; do
		if grep -Fqx "$path" <<<"$listing"; then
			fail "$archive contains obsolete software ISP path: $path"
		fi
	done
	if [[ $distribution == archlinuxarm ]]; then
		grep -Fqx usr/libexec/caihong-platform/switch-display-manager <<<"$listing" || \
			fail "$archive is missing the display-manager migration helper"
	fi
	if [[ $distribution == archlinuxarm ]]; then
		for path in \
			usr/bin/caihong-toolbox \
			usr/lib/caihong-toolbox/caihong-toolbox-service \
			usr/lib/caihong-toolbox/caihong_toolbox/gui.py \
			usr/lib/systemd/system/caihong-toolbox.service \
			usr/share/dbus-1/system-services/org.caihong.Toolbox1.service \
			usr/share/dbus-1/system.d/org.caihong.Toolbox1.conf \
			usr/share/polkit-1/actions/org.caihong.toolbox.policy \
			usr/share/applications/caihong-toolbox.desktop \
			usr/share/icons/hicolor/scalable/apps/caihong-toolbox.svg \
			usr/share/caihong/toolbox-build-info \
			usr/lib/dri/qcom_drv_video.so \
			usr/lib/dri/msm_drv_video.so \
			usr/share/caihong/vaapi-build-info \
			usr/bin/plasma-camera \
			usr/bin/cam \
			usr/bin/qcam \
			usr/lib/libcamera.so.0.7 \
			usr/lib/libcamera-base.so.0.7.2 \
			usr/lib/gstreamer-1.0/libgstlibcamera.so \
			usr/share/caihong/libcamera-build-info \
			usr/share/caihong/plasma-camera-build-info \
			usr/local/sbin/qbootctl \
			usr/share/caihong/qbootctl-build-info \
			usr/lib/power-profiles-daemon \
			usr/lib/systemd/system/power-profiles-daemon.service \
			usr/share/dbus-1/system-services/net.hadess.PowerProfiles.service \
			usr/share/polkit-1/actions/power-profiles-daemon.policy \
			usr/share/caihong/ppd-build-info \
			usr/local/libexec/caihong-adbd-serial \
			usr/local/sbin/caihong-adbd-gadget \
			usr/local/libexec/caihong-nvram-mac \
			usr/local/sbin/caihong-npu-info; do
			grep -Fqx "$path" <<<"$listing" || fail "$archive is missing $path"
		done
		if [[ $(bsdtar -xOf "$archive" usr/share/caihong/vaapi-build-info) != *source_commit=* ]]; then
			fail "$archive has no VA-API source revision metadata"
		fi
	else
		for path in \
			usr/bin/plasma-camera \
			usr/bin/cam \
			usr/bin/qcam \
			usr/lib64/libcamera.so.0.7 \
			usr/lib64/libcamera-base.so.0.7.2 \
			usr/lib64/gstreamer-1.0/libgstlibcamera.so \
			usr/lib64/dri/qcom_drv_video.so \
			usr/lib64/dri/msm_drv_video.so \
			usr/share/caihong/libcamera-build-info \
			usr/share/caihong/plasma-camera-build-info \
			usr/share/caihong/vaapi-build-info \
			usr/local/sbin/qbootctl \
			usr/share/caihong/qbootctl-build-info \
			usr/lib/power-profiles-daemon \
			usr/lib/systemd/system/power-profiles-daemon.service \
			usr/share/dbus-1/system-services/net.hadess.PowerProfiles.service \
			usr/share/polkit-1/actions/power-profiles-daemon.policy \
			usr/share/caihong/ppd-build-info \
			usr/local/libexec/caihong-adbd-serial \
			usr/local/sbin/caihong-adbd-gadget \
			usr/local/libexec/caihong-nvram-mac \
			usr/local/sbin/caihong-npu-info; do
			grep -Fqx "$path" <<<"$listing" || fail "$archive is missing $path"
		done
		if grep -Fqx 'etc/sudoers.d/10-alarm' <<<"$listing"; then
			fail "$archive contains the Arch-only alarm sudo policy"
		fi
	fi
}

verify_npu()
{
	local pointer=$1 suffix=$2 libdir=$3 archive listing path
	archive=$(resolve_pointer "$pointer" caihong-npu- "$suffix")
	[[ $(bsdtar -xOf "$archive" usr/share/caihong-npu/libdir) == "$libdir" ]] || \
		fail "$archive has incorrect libdir metadata"
	listing=$(bsdtar -tf "$archive")
	for path in \
		"usr/$libdir/libcdsprpc.so.1" \
		"usr/$libdir/caihong-npu/libcalculator.so" \
		"usr/$libdir/caihong-npu/qnn/libQnnHtp.so" \
		"usr/$libdir/caihong-npu/qnn/libQnnHtpPrepare.so" \
		"usr/$libdir/caihong-npu/qnn/libQnnHtpV75Stub.so"; do
		grep -Fqx "$path" <<<"$listing" || fail "$archive is missing $path"
	done
	for path in \
		etc/systemd/system/multi-user.target.wants/caihong-ssc.service \
		usr/libexec/caihong-platform/install-caihong-platform; do
		if grep -Fqx "$path" <<<"$listing"; then
			fail "$archive overlaps with the platform package: $path"
		fi
	done
}

verify_platform CAIHONG_PLATFORM_PACKAGE_ARCHLINUXARM \
	caihong-platform-archlinuxarm- archlinuxarm
verify_platform CAIHONG_PLATFORM_PACKAGE_ARMADA \
	caihong-platform-armada- armada
if (( ! platform_only )); then
	verify_npu CAIHONG_NPU_PACKAGE_LIB -lib.tar.zst lib
	verify_npu CAIHONG_NPU_PACKAGE_LIB64 -lib64.tar.zst lib64
	echo "verified Caihong platform and NPU update packages"
else
	echo "verified Caihong platform update packages"
fi
