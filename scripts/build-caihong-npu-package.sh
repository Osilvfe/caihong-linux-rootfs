#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
release_dir=${1:-"$project_dir/release"}
libdir=${LIBDIR:-lib}
version=$(sed -n 's/^QAIRT\/QNN v//p' "$project_dir/firmware-assets/caihong-npu/VERSION" | head -n1)
if [ -z "$version" ]; then
	echo "NPU bundle has no VERSION" >&2
	exit 1
fi
case $libdir in
	lib|lib64) ;;
	*) echo "LIBDIR must be lib or lib64" >&2; exit 2 ;;
esac

output="$release_dir/caihong-npu-$version-$libdir.tar.zst"
temporary="$output.new"
install -d -m 0755 "$release_dir"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/caihong-npu-package.XXXXXX") || exit 1
stage="$work_dir/stage"
mkdir -p "$stage"
cleanup()
{
	rm -rf "$work_dir"
	rm -f "$temporary"
}
trap cleanup EXIT HUP INT TERM

"$project_dir/scripts/install-caihong-npu.sh" \
	"$project_dir/firmware-assets/caihong-npu" "$stage" "$libdir" >/dev/null

for path in \
	libcdsprpc.so.1 \
	caihong-npu/libcalculator.so \
	caihong-npu/qnn/libQnnHtp.so \
	caihong-npu/qnn/libQnnHtpPrepare.so \
	caihong-npu/qnn/libQnnHtpV75Stub.so \
	libQnnHtp.so \
	libQnnHtpPrepare.so \
	libQnnHtpV75Stub.so; do
	if [ ! -e "$stage/usr/$libdir/$path" ] && [ ! -L "$stage/usr/$libdir/$path" ]; then
		echo "NPU package is missing usr/$libdir/$path" >&2
		exit 1
	fi
done

install -d -m 0755 "$stage/etc"

printf '%s\n' aarch64 > "$stage/usr/share/caihong-npu/architecture"
install -d -m 0755 "$stage/usr/share/caihong-package"
printf '%s\n' aarch64 > "$stage/usr/share/caihong-package/architecture"
printf '%s\n' caihong-npu > "$stage/usr/share/caihong-package/package"
printf '%s\n' "$version" > "$stage/usr/share/caihong-package/version"
printf '%s\n' "$version" > "$stage/usr/share/caihong-npu/package-version"
printf '%s\n' "$libdir" > "$stage/usr/share/caihong-npu/libdir"
: > "$stage/manifest"
while IFS= read -r file; do
	relative=${file#./}
	if [ -L "$stage/$relative" ]; then
		hash=$(readlink -- "$stage/$relative" | sha256sum | awk '{print $1}')
	else
		hash=$(sha256sum "$stage/$relative" | awk '{print $1}')
	fi
	printf '%s  ./%s\n' "$hash" "$relative" >> "$stage/manifest"
done <<EOF
$(cd "$stage" && find usr etc -mindepth 1 \( -type f -o -type l \) -print | sed 's#^#./#' | LC_ALL=C sort)
EOF

find "$stage" -xdev -type d -exec chmod 0755 {} +
find "$stage" -xdev -type f -exec chmod go-w {} +

bsdtar --uid 0 --gid 0 --uname root --gname root -cf - -C "$stage" manifest usr etc \
	| zstd -q -19 -o "$temporary"
mv "$temporary" "$output"
case $libdir in
	lib) pointer=CAIHONG_NPU_PACKAGE_LIB ;;
	lib64) pointer=CAIHONG_NPU_PACKAGE_LIB64 ;;
esac
printf '%s\n' "${output##*/}" > "$release_dir/$pointer"
printf '%s\n' "${output##*/}" > "$release_dir/CAIHONG_NPU_PACKAGE"
sha256sum "$output"

rm -rf "$work_dir"
trap - EXIT HUP INT TERM
echo "created NPU package: $output"
