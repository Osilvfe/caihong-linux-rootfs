#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
release_dir=${1:-"$project_dir/release"}
version=${CAIHONG_KERNEL_ARMADA_VERSION:-$(git -C "$project_dir" rev-parse --short HEAD)}
kernel_release=${KERNEL_RELEASE:-$(cat "$release_dir/KERNEL_RELEASE")}

for tool in bsdtar git install sha256sum zstd; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "missing build tool: $tool" >&2
		exit 1
	}
done

kernel_package_name=$(cat "$release_dir/LINUX_CAIHONG_PACKAGE")
case $kernel_package_name in
	linux-caihong-*-aarch64.pkg.tar.zst) ;;
	*) echo "invalid LINUX_CAIHONG_PACKAGE: $kernel_package_name" >&2; exit 1 ;;
esac
[ -f "$release_dir/$kernel_package_name" ] || {
	echo "missing kernel package: $kernel_package_name" >&2
	exit 1
}
staged_kernel_release=$(bsdtar -xOf "$release_dir/$kernel_package_name" \
	usr/lib/linux-caihong/kernel-release)
[ "$staged_kernel_release" = "$kernel_release" ] || {
	echo "kernel package release $staged_kernel_release does not match $kernel_release" >&2
	exit 1
}

output="$release_dir/caihong-kernel-armada-$version.tar.zst"
temporary="$output.new"
install -d -m 0755 "$release_dir"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/caihong-kernel-armada.XXXXXX") || exit 1
stage="$work_dir/stage"
package_stage="$work_dir/package"
mkdir -p "$stage" "$package_stage"
cleanup()
{
	rm -rf "$work_dir"
	rm -f "$temporary"
}
trap cleanup EXIT HUP INT TERM

bsdtar -xf "$release_dir/$kernel_package_name" -C "$package_stage" usr
install -d -m 0755 \
	"$stage/usr/share/caihong-package" \
	"$stage/usr/share/caihong-kernel" \
	"$stage/usr/libexec/caihong-platform"
install -m 0755 \
	"$project_dir/packaging/caihong-kernel-armada/install-caihong-kernel" \
	"$stage/usr/libexec/caihong-platform/install-caihong-kernel"
cp -a "$package_stage/usr/." "$stage/usr/"
rm -rf -- "$stage/usr/lib/linux-caihong/modules"
rm -rf -- "$stage/usr/lib/modules"
mkdir -p "$stage/usr/lib/modules"
mv -- "$package_stage/usr/lib/linux-caihong/modules/$kernel_release" \
	"$stage/usr/lib/modules/$kernel_release"
printf '%s\n' aarch64 > "$stage/usr/share/caihong-package/architecture"
printf '%s\n' caihong-kernel-armada > "$stage/usr/share/caihong-package/package"
printf '%s\n' "$version" > "$stage/usr/share/caihong-package/version"
printf '%s\n' "$kernel_release" \
	> "$stage/usr/share/caihong-kernel/kernel-release"

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
$(cd "$stage" && find usr -mindepth 1 \( -type f -o -type l \) -print | LC_ALL=C sort)
EOF

find "$stage" -xdev -type d -exec chmod 0755 {} +
find "$stage" -xdev -type f -exec chmod go-w {} +
chmod 0755 "$stage/usr/libexec/caihong-platform/install-caihong-kernel"

bsdtar --uid 0 --gid 0 --uname root --gname root -cf - -C "$stage" manifest usr |
	zstd -q -19 -o "$temporary"
mv -- "$temporary" "$output"
bsdtar -xOf "$output" usr/lib/linux-caihong/kernel-release |
	grep -Fxq "$kernel_release"
if bsdtar -tf "$output" | grep -q '^usr/lib/linux-caihong/modules/'; then
	echo "Armada kernel package must not duplicate the standard module tree" >&2
	exit 1
fi
printf '%s\n' "${output##*/}" > "$release_dir/CAIHONG_KERNEL_ARMADA_PACKAGE"
sha256sum "$output"

rm -rf "$work_dir"
trap - EXIT HUP INT TERM
echo "created Armada kernel package: $output"
