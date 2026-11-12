#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
#
# Build qbootctl into an update-package stage from the prepared AArch64 build
# root.  qbootctl was previously built separately by each rootfs packager.
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=${1:-}
build_root=${CAIHONG_BUILD_ROOT:-}
source_tree="$project_dir/external/qbootctl"

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
[[ -f $source_tree/meson.build ]] || {
	echo "missing qbootctl source; run scripts/checkout-dependencies.sh" >&2
	exit 1
}
for tool in chroot git meson rsync; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "missing host tool: $tool" >&2
		exit 1
	}
done

work_dir=$(mktemp -d "$project_dir/build/caihong-qbootctl-stage.XXXXXX")
source_copy="$work_dir/qbootctl"
cleanup()
{
	rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$source_copy"
rsync -aHAX --numeric-ids --exclude=.git --exclude=build \
	"$source_tree/" "$source_copy/"
install -d -m 0755 "$build_root/var/tmp"
rm -rf -- "$build_root/var/tmp/caihong-qbootctl-src" \
	"$build_root/var/tmp/caihong-qbootctl-install"
rsync -aHAX --numeric-ids "$source_copy/" "$build_root/var/tmp/caihong-qbootctl-src/"

chroot_env=(/usr/bin/env -i HOME=/root LANG=C
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
chroot "$build_root" "${chroot_env[@]}" \
	meson setup /var/tmp/caihong-qbootctl-build /var/tmp/caihong-qbootctl-src \
	--buildtype=release --prefix=/usr/local --bindir=sbin
chroot "$build_root" "${chroot_env[@]}" \
	meson compile -C /var/tmp/caihong-qbootctl-build
chroot "$build_root" "${chroot_env[@]}" \
	/usr/bin/env DESTDIR=/var/tmp/caihong-qbootctl-install \
	meson install -C /var/tmp/caihong-qbootctl-build --no-rebuild

if [[ ! -x $build_root/var/tmp/caihong-qbootctl-install/usr/local/sbin/qbootctl ]]; then
	echo "qbootctl install failed" >&2
	exit 1
fi
install -D -m 0755 "$build_root/var/tmp/caihong-qbootctl-install/usr/local/sbin/qbootctl" \
	"$stage/usr/local/sbin/qbootctl"
file "$stage/usr/local/sbin/qbootctl" | grep -q 'ARM aarch64' || {
	echo "qbootctl is not AArch64" >&2
	exit 1
}
if [[ -d $source_tree/.git ]]; then
	source_commit=$(git -C "$source_tree" rev-parse --verify HEAD)
else
	source_commit=$(sed -n 's/^QBOOTCTL_COMMIT=//p' \
		"$project_dir/build/dependencies.resolved.env" 2>/dev/null | tail -n 1)
fi
if [[ -n $source_commit ]]; then
	install -d -m 0755 "$stage/usr/share/caihong"
	printf 'source_commit=%s\n' "$source_commit" \
		> "$stage/usr/share/caihong/qbootctl-build-info"
	chmod 0644 "$stage/usr/share/caihong/qbootctl-build-info"
fi
rm -rf -- "$build_root/var/tmp/caihong-qbootctl-src" \
	"$build_root/var/tmp/caihong-qbootctl-build" \
	"$build_root/var/tmp/caihong-qbootctl-install"
echo "qbootctl staged for the platform package"
