#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
release_dir=${1:-"$project_dir/release"}
version=${CAIHONG_PLATFORM_VERSION:-$(git -C "$project_dir" rev-parse --short HEAD)}
libdir=${LIBDIR:-lib}
kernel_release=${KERNEL_RELEASE:-}
distribution=${DISTRIBUTION:-archlinuxarm}

for tool in bsdtar file git install sha256sum zstd; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "missing build tool: $tool" >&2
		exit 1
	fi
done
case $libdir in
	lib|lib64) ;;
	*) echo "LIBDIR must be lib or lib64" >&2; exit 2 ;;
esac
case $distribution in
	archlinuxarm|armada) ;;
	*) echo "DISTRIBUTION must be archlinuxarm or armada" >&2; exit 2 ;;
esac
if [ -n "$kernel_release" ] && [ ! -d "$project_dir/modules-current/lib/modules/$kernel_release" ]; then
	echo "KERNEL_RELEASE does not exist in modules-current: $kernel_release" >&2
	exit 1
fi
if [ -z "$kernel_release" ]; then
	kernel_release=$(cat "$project_dir/release/KERNEL_RELEASE" 2>/dev/null || true)
fi
if [ -z "$kernel_release" ]; then
	for candidate in "$project_dir"/modules-current/lib/modules/*; do
		[ -d "$candidate" ] || continue
		[ -z "${found_release:-}" ] || {
			echo "module tree contains multiple kernel releases; set KERNEL_RELEASE" >&2
			exit 1
		}
		found_release=${candidate##*/}
	done
	kernel_release=${found_release:-}
fi
[ -n "$kernel_release" ] || echo "warning: kernel release is unknown; installer will not enforce it" >&2

output="$release_dir/caihong-platform-$distribution-$version.tar.zst"
temporary="$output.new"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/caihong-platform-package.XXXXXX") || exit 1
stage="$work_dir/stage"
mkdir -p "$release_dir" "$stage/usr" "$stage/etc"
find "$stage" -xdev -type d -exec chmod 0755 {} +
find "$stage" -xdev -type f -exec chmod go-w {} +

cleanup()
{
	rm -rf "$work_dir"
	rm -f "$temporary"
}
trap cleanup EXIT HUP INT TERM

cp -a "$project_dir/rootfs/archlinuxarm/." "$stage/"
if [ "$distribution" = armada ]; then
	cp -a "$project_dir/rootfs/armada/." "$stage/"
	for path in \
		etc/systemd/system/caihong-clean-pogo-kde.service \
		usr/local/sbin/caihong-clean-pogo-kde \
		usr/local/sbin/caihong-fix-kwin-brightness; do
		sed -i \
			-e 's#/home/alarm#/var/home/armada#g' \
			-e 's#machine=alarm@#machine=armada@#g' \
			-e 's#-o alarm -g alarm#-o armada -g armada#g' \
			-e 's#chown alarm:alarm#chown armada:armada#g' \
			"$stage/$path"
		if grep -Eq '/home/alarm|machine=alarm@' "$stage/$path"; then
			echo "unadapted Armada account reference: $path" >&2
			exit 1
		fi
	done
	sed -i 's#/usr/bin/resize2fs#/usr/sbin/resize2fs#g' \
		"$stage/etc/systemd/system/caihong-grow-rootfs.service"
fi

(
	cd "$project_dir/firmware" && sha256sum -c SHA256SUMS >/dev/null
)
install -d -m 0755 "$stage/usr/lib/firmware"
cp -a "$project_dir/firmware/." "$stage/usr/lib/firmware/"
rm -f "$stage/usr/lib/firmware/SOURCE.md" "$stage/usr/lib/firmware/SHA256SUMS"

mkdir -p "$stage/usr/lib/firmware/qcom/sm8650"
if command -v alsatplg >/dev/null 2>&1; then
	"$project_dir/scripts/build-caihong-audioreach-topology.sh" \
		"$stage/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin" >/dev/null
else
	install -m 0644 "$project_dir/firmware/qcom/sm8650/SM8650-MTP-tplg.bin" \
		"$stage/usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin"
fi

CAIHONG_ADBD_CACHE="$project_dir/downloads/caihong-adbd" \
	"$project_dir/scripts/install-caihong-adbd.sh" "$stage" >/dev/null
FORCE=1 "$project_dir/scripts/ssc/install-rootfs.sh" \
	"$project_dir/firmware-assets/caihong-ssc" "$stage" >/dev/null

install -D -m 0755 \
	"$project_dir/packaging/caihong-platform/install-caihong-platform" \
	"$stage/usr/libexec/caihong-platform/install-caihong-platform"
install -d -m 0755 "$stage/usr/share/caihong-package"
install -d -m 0755 "$stage/usr/share/caihong-platform"
printf '%s\n' aarch64 > "$stage/usr/share/caihong-package/architecture"
printf '%s\n' caihong-platform > "$stage/usr/share/caihong-package/package"
printf '%s\n' "$version" > "$stage/usr/share/caihong-package/version"
printf '%s\n' "$distribution" > "$stage/usr/share/caihong-platform/distribution"
[ -z "$kernel_release" ] || printf '%s\n' "$kernel_release" \
	> "$stage/usr/share/caihong-platform/kernel-release"
printf '%s\n' "libdir=$libdir" \
	> "$stage/usr/share/caihong-platform/layout"

manifest="$stage/manifest"
cat > "$stage/remove" <<'EOF'
usr/share/caihong-package/architecture
usr/share/caihong-package/package
usr/share/caihong-package/version
usr/share/libcamera/ipa/simple/sc1320cs.yaml
usr/share/libcamera/ipa/simple/sc820cs.yaml
EOF
: > "$manifest"
while IFS= read -r file; do
	relative=${file#./}
	if [ -L "$stage/$relative" ]; then
		hash=$(readlink -- "$stage/$relative" | sha256sum | awk '{print $1}')
	else
		hash=$(sha256sum "$stage/$relative" | awk '{print $1}')
	fi
	printf '%s  ./%s\n' "$hash" "$relative" >> "$manifest"
done <<EOF
$(cd "$stage" && { find usr etc -mindepth 1 \( -type f -o -type l \) -print | sed 's#^#./#'; printf '%s\n' ./remove; } | LC_ALL=C sort)
EOF

rm -f "$temporary"
install -d -m 0755 "$release_dir"
bsdtar --uid 0 --gid 0 --uname root --gname root -cf - -C "$stage" manifest remove usr etc \
	| zstd -q -19 -o "$temporary"
mv "$temporary" "$output"

bsdtar -tf "$output" | grep -qx 'manifest'
bsdtar -xOf "$output" manifest > "$work_dir/verify-manifest"
cmp "$manifest" "$work_dir/verify-manifest"
case $distribution in
	archlinuxarm) pointer=CAIHONG_PLATFORM_PACKAGE_ARCHLINUXARM ;;
	armada) pointer=CAIHONG_PLATFORM_PACKAGE_ARMADA ;;
esac
printf '%s\n' "${output##*/}" \
	> "$release_dir/$pointer"
printf '%s\n' "${output##*/}" \
	> "$release_dir/CAIHONG_PLATFORM_PACKAGE"
sha256sum "$output"

rm -rf "$work_dir"
trap - EXIT HUP INT TERM
echo "created platform package: $output"
