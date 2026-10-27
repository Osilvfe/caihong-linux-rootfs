#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
target=${1:-}
if [[ -z $target || ! -d $target ]]; then
	echo "usage: $0 ROOTFS_DIR" >&2
	exit 2
fi
target=$(cd -- "$target" && pwd)
failed=0

missing()
{
	echo "missing required Armada rootfs path: /$1" >&2
	failed=1
}

require_path()
{
	[[ -e $target/$1 || -L $target/$1 ]] || missing "$1"
}

grep -qx 'ID=armada' "$target/usr/lib/os-release" 2>/dev/null || {
	echo "rootfs identity is not Armada" >&2
	failed=1
}
grep -qx 'distribution=armada' "$target/etc/caihong-rootfs-build-info" 2>/dev/null || {
	echo "Caihong build information does not identify Armada" >&2
	failed=1
}
grep -Eq '^armada_digest=sha256:[0-9a-f]{64}$' \
	"$target/etc/caihong-rootfs-build-info" 2>/dev/null || {
	echo "resolved Armada digest is missing" >&2
	failed=1
}

required_paths=(
	var/home/armada
	var/home/armada/.local/share/Steam/steamrtarm64/steam
	usr/bin/gamescope
	usr/bin/FEX
	usr/bin/bootc
	usr/bin/cam
	usr/bin/qcam
	usr/bin/plasma-camera
	usr/lib64/gstreamer-1.0/libgstlibcamera.so
	usr/lib64/libcamera-base.so.0.7.2
	usr/lib64/libcamera.so.0.7
	usr/lib64/libcamera.so.0.7.2
	usr/share/caihong/libcamera-build-info
	usr/share/caihong/plasma-camera-build-info
	etc/issue.d/20-caihong-armada.issue
	usr/share/doc/caihong-armada/SOURCES-AND-LICENSES.md
	usr/local/libexec/caihong-nvram-mac
	usr/local/sbin/caihong-npu-info
	usr/local/libexec/caihong-npu-htp-self-test
	usr/local/libexec/caihong-npu-htp-conv-test
	usr/lib64/libcdsprpc.so.1
	usr/lib64/caihong-npu/libcalculator.so
	usr/lib64/caihong-npu/qnn/libQnnHtp.so
	usr/lib64/caihong-npu/qnn/libQnnHtpPrepare.so
	usr/lib64/caihong-npu/qnn/libQnnHtpV75Stub.so
	usr/lib64/libQnnHtp.so
	usr/lib64/libQnnHtpPrepare.so
	usr/lib64/libQnnHtpV75Stub.so
	usr/bin/adbd
	usr/lib/caihong-adbd/runtime
	usr/lib/caihong-adbd/libprotobuf.so.32
	usr/lib/dsp/fastrpc_shell_unsigned_3
	usr/lib/dsp/libcalculator_skel.so
	usr/lib/dsp/libQnnHtpV75Skel.so
	usr/lib/dsp/libc++.so.1
	usr/lib/dsp/libc++abi.so.1
	usr/share/caihong-npu/dsp/v75/fastrpc_shell_unsigned_3
	usr/share/caihong-npu/dsp/v75/libcalculator_skel.so
	usr/share/caihong-npu/dsp/v75/libQnnHtpV75Skel.so
	usr/share/caihong-npu/dsp/v75/libc++.so.1
	usr/share/caihong-npu/dsp/v75/libc++abi.so.1
	usr/share/licenses/caihong-npu/LICENSE.fastrpc
	usr/share/licenses/caihong-npu/LICENSE.geniex-qairt-plugin
	usr/share/licenses/caihong-npu/THIRD_PARTY_NOTICES.QAIRT.md
	usr/local/sbin/qbootctl
	usr/local/sbin/caihong-slot
	usr/local/sbin/caihong-flashlight
	usr/local/sbin/caihong-hotspot
	usr/local/sbin/caihong-pen-charge
	usr/local/sbin/caihong-adbd-gadget
	usr/local/sbin/caihong-adbd-run
	usr/lib/linux-caihong/Image
	usr/lib/linux-caihong/caihong.dtb
	usr/lib/linux-caihong/boot-linux.img
	usr/lib/linux-caihong/boot-userdata.img
	usr/lib/linux-caihong/kernel-release
	usr/share/alsa/ucm2/Qualcomm/sm8650/Caihong/HiFi.conf
	usr/local/libexec/caihong-ssc/hexagonrpcd
	usr/local/libexec/caihong-ssc/iio-sensor-proxy
	usr/local/lib/caihong-ssc/libhexagonrpc.so.0.5
	usr/local/lib/caihong-ssc/libssc.so.2
	usr/lib/systemd/system/iio-sensor-proxy.service.d/caihong-ssc.conf
	usr/lib/tmpfiles.d/caihong-alsa.conf
	usr/lib/udev/rules.d/99-caihong-flashlight.rules
	usr/lib/udev/rules.d/99-caihong-fastrpc.rules
	usr/lib/firmware/ath12k/WCN7850/hw2.0/board-2.bin
	usr/lib/firmware/awinic/caihong-aw88261-acf.bin
	usr/lib/firmware/novatek/DT-novatek-nt36532.bin
	usr/lib/firmware/qcom/sm8650/CAMERA_ICP.mbn
	usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin
	usr/lib/firmware/qcom/sm8650/Oneplus/caihong/vpu33_4v.mbn
	usr/lib/firmware/qcom/sm8650/bps-striping-bggr10-nv12-3264x2448.bin
	usr/lib/firmware/qcom/sm8650/bps-striping-bggr10-nv12-4208x3120.bin
	usr/lib/firmware/qcom/sm8650/bps-striping-bggr10-nv12-640x480.bin
	etc/modules-load.d/armada-handheld.conf
	etc/udev/rules.d/99-caihong-dma-heap.rules
	etc/systemd/system/caihong-pen-charge.service
	etc/systemd/system/multi-user.target.wants/caihong-hardware-mac.service
	etc/systemd/system/multi-user.target.wants/caihong-adbd.service
	etc/systemd/system/multi-user.target.wants/caihong-mark-boot-successful.service
	etc/systemd/system/multi-user.target.wants/caihong-ssc.service
	etc/systemd/system/timers.target.wants/caihong-bluetooth-late-autostart.timer
	etc/systemd/system/timers.target.wants/caihong-pen-autoconnect.timer
	etc/systemd/system/timers.target.wants/caihong-pen-charge.timer
	etc/systemd/system/timers.target.wants/caihong-pen-pair.timer
	etc/systemd/system/armada-update-reserve.service
	etc/systemd/system/armada-controller-type.service
	etc/systemd/system/bootc-generic-growpart.service
)
for path in "${required_paths[@]}"; do
	require_path "$path"
done

pen_script="$target/usr/local/sbin/caihong-pen-charge"
pen_service="$target/etc/systemd/system/caihong-pen-charge.service"
if grep -q '/usr/local/lib/caihong/caihong_pen_power\.ko' \
	"$pen_script" "$pen_service" 2>/dev/null || \
	[[ -e $target/usr/local/lib/caihong/caihong_pen_power.ko ]]; then
	echo "obsolete standalone pen module copy is present" >&2
	failed=1
fi
if ! grep -Fq 'subprocess.run(["modprobe", module_name]' "$pen_script" 2>/dev/null; then
	echo "pen charge helper does not load from the standard module tree" >&2
	failed=1
fi

if [[ -e $target/etc/alsa/state-daemon.conf ]]; then
	echo "ALSA state daemon mode must be disabled in Armada" >&2
	failed=1
fi

obsolete_camera_paths=(
	usr/lib/libcamera/ipa/ipa_soft_simple.so
	usr/lib/libcamera/ipa/ipa_soft_simple.so.sign
	usr/lib/libcamera/soft_ipa_proxy
	usr/include/libcamera/libcamera/ipa/soft_ipa_interface.h
	usr/lib64/libcamera/ipa/ipa_soft_simple.so
	usr/lib64/libcamera/ipa/ipa_soft_simple.so.sign
	usr/lib64/libcamera/soft_ipa_proxy
	usr/lib/libcamera/soft_ipa_proxy
	usr/lib64/libcamera/soft_ipa_proxy
	usr/libexec/libcamera/soft_ipa_proxy
	usr/share/libcamera/ipa/simple/sc1320cs.yaml
	usr/share/libcamera/ipa/simple/sc820cs.yaml
)
for path in "${obsolete_camera_paths[@]}"; do
	if [[ -e $target/$path || -L $target/$path ]]; then
		echo "obsolete software ISP path remains in Armada rootfs: /$path" >&2
		failed=1
	fi
done

for package in libcamera libcamera-ipa libcamera-tools; do
	if rpm --root "$target" -q "$package" >/dev/null 2>&1; then
		echo "obsolete distribution camera package remains: $package" >&2
		failed=1
	fi
done

libcamera_commit=$(git -C "$project_dir/external/libcamera" rev-parse --verify HEAD)
plasma_camera_commit=$(git -C "$project_dir/external/plasma-camera" rev-parse --verify HEAD)
grep -qx "source_commit=$libcamera_commit" \
	"$target/usr/share/caihong/libcamera-build-info" 2>/dev/null || {
	echo "Armada libcamera source commit does not match the workspace" >&2
	failed=1
}
grep -qx 'libdir=lib64' \
	"$target/usr/share/caihong/libcamera-build-info" 2>/dev/null || {
	echo "Armada libcamera was not installed in /usr/lib64" >&2
	failed=1
}
for setting in pipelines=simple ipas=none \
	isp_backend=qcom-camera-icp-bps isp_output=nv12m \
	isp_statistics=output-luma-chroma-sampling \
	isp_pipeline=raw10-demosaic-white-balance-ccm-nv12m \
	color_correction=sensor-profile-ccm \
	gamma=deferred-until-pre-gamma-white-balance \
	module_abi=qcom-camera-icp-bps-matched-build \
	isp_validation=front-3264x2448-rear-4208x3120 \
	validated_camera_sensors=sc820cs,sc1320cs \
	sensor_controls=closed-loop-exposure-gain \
	software_isp=disabled software_isp_linkage=omitted \
	software_isp_fallback=disabled \
	softisp_gpu=disabled ae_controls=unavailable \
	auto_exposure=output-luma-closed-loop \
	awb_controls=v4l2-red-blue-balance-q10 \
	white_balance=sensor-profile-plus-adaptive \
	auto_white_balance=output-chroma-closed-loop \
	autofocus=manual-position; do
	grep -qx "$setting" \
		"$target/usr/share/caihong/libcamera-build-info" 2>/dev/null || {
		echo "missing Armada libcamera hardware ISP setting: $setting" >&2
		failed=1
	}
done
while IFS= read -r setting; do
	if ! grep -Eq "^${setting}=.+$" \
		"$target/usr/share/caihong/libcamera-build-info" 2>/dev/null; then
		echo "missing non-empty Armada libcamera setting: $setting" >&2
		failed=1
	fi
done <<'EOF'
build_id
build_profile
build_timestamp
EOF
grep -qx "source_commit=$plasma_camera_commit" \
	"$target/usr/share/caihong/plasma-camera-build-info" 2>/dev/null || {
	echo "Armada Plasma Camera source commit does not match the workspace" >&2
	failed=1
}

for unit in armada-controller-type.service armada-update-reserve.service \
	bootc-generic-growpart.service; do
	mask="$target/etc/systemd/system/$unit"
	if [[ ! -L $mask || $(readlink "$mask") != /dev/null ]]; then
		echo "direct-root Armada service is not masked: $unit" >&2
		failed=1
	fi
done

if ! find "$target/usr" "$target/var" -xdev \
	-type f -name proton -path '*/compatibilitytools.d/*' -print -quit 2>/dev/null |
	grep -q .; then
	echo "Armada Proton component is missing" >&2
	failed=1
fi

mapfile -t module_releases < <(
	find "$target/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d \
		-printf '%f\n' 2>/dev/null
)
if (( ${#module_releases[@]} != 1 )); then
	echo "Armada rootfs must contain exactly one kernel module release" >&2
	failed=1
else
	kernel_release=${module_releases[0]}
	module_dir="$target/usr/lib/modules/$kernel_release"
	for metadata in modules.dep modules.alias modules.builtin; do
		[[ -s $module_dir/$metadata ]] || missing "usr/lib/modules/$kernel_release/$metadata"
	done
	if ! grep -q '/msm\.ko$' "$module_dir/modules.builtin"; then
		msm_module=$(find "$module_dir" -type f -name msm.ko -print -quit)
		if [[ -z $msm_module ]]; then
			echo "missing release kernel module: msm" >&2
			failed=1
		elif ! modinfo -F vermagic "$msm_module" 2>/dev/null |
			grep -q "^$kernel_release "; then
			echo "kernel module release mismatch: msm" >&2
			failed=1
		fi
	fi
	for module in oneplus_pogo nt36532e_ts sc8547_cp caihong_pen_power \
		bnep rfcomm hidp veth bridge br_netfilter nft_compat xt_CHECKSUM \
		zram zstd fuse cpufreq_conservative snd-seq hid-steam hid-nintendo \
		hid-playstation hid-sony \
		xpad \
		xt_MASQUERADE system_heap cma_heap nvmem-reboot-mode nvmem_qcom-spmi-sdam \
		videocc-sm8550 qcom-iris sc820cs sc1320cs gt9772 \
		qcom_camera_icp qcom-camera-icp-bps \
		ath12k_wifi7 qcom_q6v5_pas; do
		module_file=$(find "$module_dir" -type f -name "$module.ko" -print -quit)
		if [[ -z $module_file ]]; then
			echo "missing release kernel module: $module" >&2
			failed=1
			continue
		fi
		vermagic=$(modinfo -F vermagic "$module_file" 2>/dev/null || true)
		[[ $vermagic == "$kernel_release "* ]] || {
			echo "kernel module release mismatch: $module" >&2
			failed=1
		}
	done
	cmp -s "$target/usr/lib/linux-caihong/kernel-release" \
		<(printf '%s\n' "$kernel_release") || {
		echo "kernel metadata does not match module tree" >&2
		failed=1
	}
fi

for file in \
	"$target/etc/systemd/system/caihong-clean-pogo-kde.service" \
	"$target/usr/local/sbin/caihong-clean-pogo-kde" \
	"$target/usr/local/sbin/caihong-fix-kwin-brightness"; do
	if grep -q '/home/alarm\|machine=alarm@' "$file"; then
		echo "unadapted Arch Linux ARM account in ${file#"$target"}" >&2
		failed=1
	fi
done
grep -q '/var/home/armada' \
	"$target/usr/local/sbin/caihong-fix-kwin-brightness" || {
	echo "Armada KWin integration does not target the Armada account" >&2
	failed=1
}
[[ ! -e $target/etc/sudoers.d/10-alarm ]] || {
	echo "Arch Linux ARM sudo policy leaked into Armada" >&2
	failed=1
}
grep -qx 'LANG=en_US.UTF-8' "$target/etc/locale.conf" || {
	echo "Armada default locale must be en_US.UTF-8" >&2
	failed=1
}

if (( failed )); then
	exit 1
fi
echo "verified Caihong Armada rootfs: $target"
