#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
output=${1:-"$project_dir/release/caihong-boot.img"}
kernel=${2:-"$project_dir/linux/out/arch/arm64/boot/Image"}
dtb=${3:-"$project_dir/linux/out/arch/arm64/boot/dts/qcom/sm8650-oneplus-caihong.dtb"}
cmdline_file=${CMDLINE_FILE:-"$project_dir/config/caihong-direct-root-cmdline.txt"}
root_partlabel=${ROOT_PARTLABEL:-linux}
temporary="$output.new"

case "$root_partlabel" in
	linux|userdata) ;;
	*) echo "unsupported root partition label: $root_partlabel" >&2; exit 2 ;;
esac

for tool in python3 sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "missing tool: $tool" >&2
		exit 1
	}
done

if [ -n "${MKBOOTIMG:-}" ]; then
	[ -f "$MKBOOTIMG" ] || {
		echo "missing mkbootimg source: $MKBOOTIMG" >&2
		exit 1
	}
	mkbootimg=$MKBOOTIMG
elif [ -f "$project_dir/external/mkbootimg/mkbootimg.py" ]; then
	mkbootimg="$project_dir/external/mkbootimg/mkbootimg.py"
elif command -v mkbootimg >/dev/null 2>&1; then
	mkbootimg=$(command -v mkbootimg)
else
	echo "missing mkbootimg.py; run scripts/checkout-dependencies.sh" >&2
	exit 1
fi
for file in "$kernel" "$dtb" "$cmdline_file"; do
	[ -f "$file" ] || {
		echo "missing input: $file" >&2
		exit 1
	}
done

mkdir -p "$(dirname -- "$output")"
if [ -e "$output" ] && [ "${FORCE:-0}" != 1 ]; then
	echo "refusing to overwrite existing output: $output" >&2
	exit 1
fi
rm -f -- "$temporary"
IFS= read -r cmdline < "$cmdline_file"
case " $cmdline " in
	*" root=PARTLABEL=$root_partlabel "*) ;;
	*) echo "direct-root command line is missing root=PARTLABEL=$root_partlabel" >&2; exit 1 ;;
esac
case " $cmdline " in
	*' rdinit='*|*' root=LABEL='*)
		echo "direct-root command line still references an initramfs root" >&2
		exit 1
		;;
esac

cleanup()
{
	rm -f -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

# Android boot header v2 carries only Image and the dedicated DTB payload.
# No --ramdisk argument is passed, so ramdisk_size is exactly zero.
python3 "$mkbootimg" \
	--base 0x00000000 \
	--kernel_offset 0x00008000 \
	--ramdisk_offset 0x01000000 \
	--second_offset 0x00f00000 \
	--tags_offset 0x00000100 \
	--dtb_offset 0x04000000 \
	--pagesize 4096 \
	--header_version 2 \
	--os_version 16.0.0 \
	--os_patch_level 2026-06 \
	--kernel "$kernel" \
	--dtb "$dtb" \
	--cmdline "$cmdline" \
	--output "$temporary"

mv -- "$temporary" "$output"
trap - EXIT HUP INT TERM
echo "created direct-root boot image: $output"
sha256sum "$output"
